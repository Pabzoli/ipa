import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import 'player_statistics_provider.dart';

class PInform extends StatefulWidget {
  const PInform({super.key});

  @override
  State<PInform> createState() => _PInformState();
}

class _PInformState extends State<PInform> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  String _username        = 'Trainer';
  bool   _usernameLoading = true;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final name = await FirestoreService.instance.getUsername();
    if (mounted) setState(() { _username = name; _usernameLoading = false; });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── Streak Shield purchase (30 AC) ─────────────────────────────────────────
  Future<void> _buyStreakShield() async {
    const cost = 30;
    final userData = context.read<UserDataProvider>();

    if (userData.animeCoins < cost) {
      if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Protect Your Streak?',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Spend 30🪙 to activate a Streak Shield.\n\n'
          'If you miss a day, the shield absorbs it and your streak is preserved. '
          'One shield can be active at a time.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '🛡 Activate  −30🪙',
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await userData.spendCoins(cost, 'spend_streak_shield');
      await userData.setStreakShieldActive(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🛡 Streak Shield activated!'),
            backgroundColor: AppColors.correct,
          ),
        );
      }
    } on InsufficientCoinsException {
      if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
    } catch (e) {
      debugPrint('Unexpected error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong — please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats        = context.watch<PlayerStatisticsProvider>().playerStatistics;
    final udp          = context.watch<UserDataProvider>();
    final weeklyPoints = udp.weeklyPoints;
    final animeCoins   = udp.animeCoins;
    final shieldActive = udp.streakShieldActive;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            backgroundColor: AppColors.surfaceDim,
            leading: BackButton(color: AppColors.textPrimary),
            flexibleSpace: FlexibleSpaceBar(
              background: _ProfileHeader(
                username:     _usernameLoading ? '...' : _username,
                weeklyPoints: weeklyPoints,
                animeCoins:   animeCoins,
                onEditName:   () => _showEditUsername(context),
              ),
            ),
            bottom: TabBar(
              controller:           _tabCtrl,
              labelColor:           AppColors.primary,
              unselectedLabelColor: AppColors.textMuted,
              indicatorColor:       AppColors.primary,
              indicatorWeight:      3,
              dividerColor:         AppColors.divider,
              isScrollable:         true,
              tabAlignment:         TabAlignment.start,
              tabs: const [
                Tab(text: 'Statistics'),
                Tab(text: 'Achievements'),
                Tab(text: 'History'),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _StatisticsTab(
              stats:        stats,
              shieldActive: shieldActive,
              onBuyShield:  _buyStreakShield,
            ),
            const _AchievementsTab(),
            const _HistoryTab(),
          ],
        ),
      ),
    );
  }

  void _showEditUsername(BuildContext context) async {
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
            'You can change your username again in $daysLeft day${daysLeft == 1 ? '' : 's'}.',
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
                const SnackBar(content: Text('Username updated!')),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(e.toString().replaceFirst('Exception: ', '')),
                  backgroundColor: AppColors.wrong,
                ),
              );
            }
          }
        },
      ),
    );
  }
}

// ─── Edit Username Dialog ────────────────────────────────────────────────────
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
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800)),
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
          const SizedBox(height: 6),
          const Text(
            '⚠ Username can only be changed once every 7 days.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
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
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ─── Profile Header ───────────────────────────────────────────────────────────
class _ProfileHeader extends StatelessWidget {
  final String   username;
  final int      weeklyPoints;
  final int      animeCoins;
  final VoidCallback onEditName;

  const _ProfileHeader({
    required this.username,
    required this.weeklyPoints,
    required this.animeCoins,
    required this.onEditName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.heroBg,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, Color(0xFFFF6B6B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.4), blurRadius: 16)],
            ),
            child: const Icon(Icons.person_rounded, color: Colors.white, size: 42),
          ),
          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Username row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        username,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: onEditName,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: AppColors.surface.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: const Icon(Icons.edit_rounded,
                            color: AppColors.textMuted, size: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Stat badges
                Row(
                  children: [
                    _HeaderBadge(
                      icon:  Icons.stars_rounded,
                      label: '$weeklyPoints WP',
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 8),
                    _HeaderBadge(
                      emoji: '🪙',
                      label: '$animeCoins AC',
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderBadge extends StatelessWidget {
  final IconData? icon;
  final String?   emoji;
  final String    label;
  final Color     color;

  const _HeaderBadge({this.icon, this.emoji, required this.label, required this.color})
      : assert(icon != null || emoji != null);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon  != null) Icon(icon, color: color, size: 14),
        if (emoji != null) Text(emoji!, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13)),
      ]),
    );
  }
}

// ─── Statistics Tab ───────────────────────────────────────────────────────────
class _StatisticsTab extends StatelessWidget {
  final PlayerStatistics stats;
  final bool             shieldActive;
  final VoidCallback     onBuyShield;

  const _StatisticsTab({
    required this.stats,
    required this.shieldActive,
    required this.onBuyShield,
  });

  @override
  Widget build(BuildContext context) {
    final total = stats.gamesPlayed;
    final winPct  = total > 0 ? stats.gamesWon  / total : 0.0;
    final drawPct = total > 0 ? stats.gamesDraw / total : 0.0;
    final losePct = total > 0 ? stats.gamesLost / total : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Streak Shield ─────────────────────────────────────────────────
          _StreakShieldCard(active: shieldActive, onBuy: onBuyShield),
          const SizedBox(height: 24),

          // ── Match Record header ───────────────────────────────────────────
          const SectionHeader(title: 'Match Record'),
          const SizedBox(height: 14),

          // W / D / L big cards
          Row(children: [
            Expanded(child: _BigStatCard(
              value: '${stats.gamesWon}',
              label: 'Wins',
              icon:  Icons.emoji_events_rounded,
              color: AppColors.correct,
            )),
            const SizedBox(width: 10),
            Expanded(child: _BigStatCard(
              value: '${stats.gamesDraw}',
              label: 'Draws',
              icon:  Icons.handshake_rounded,
              color: AppColors.accent,
            )),
            const SizedBox(width: 10),
            Expanded(child: _BigStatCard(
              value: '${stats.gamesLost}',
              label: 'Losses',
              icon:  Icons.close_rounded,
              color: AppColors.wrong,
            )),
          ]),
          const SizedBox(height: 12),

          // Games Played + WLD bar
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Column(children: [
              Row(children: [
                const Icon(Icons.sports_esports_rounded,
                    color: AppColors.secondary, size: 20),
                const SizedBox(width: 10),
                const Text('Games Played',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                const Spacer(),
                Text('$total',
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w900)),
              ]),

              if (total > 0) ...[
                const SizedBox(height: 12),
                // WDL ratio bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Row(children: [
                    if (stats.gamesWon  > 0) Expanded(flex: (winPct  * 100).round(), child: Container(height: 8, color: AppColors.correct)),
                    if (stats.gamesDraw > 0) Expanded(flex: (drawPct * 100).round(), child: Container(height: 8, color: AppColors.accent)),
                    if (stats.gamesLost > 0) Expanded(flex: (losePct * 100).round(), child: Container(height: 8, color: AppColors.wrong)),
                    if (total == 0) Expanded(child: Container(height: 8, color: AppColors.divider)),
                  ]),
                ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  _WDLLabel(color: AppColors.correct, label: '${(winPct  * 100).toStringAsFixed(0)}% W'),
                  _WDLLabel(color: AppColors.accent,  label: '${(drawPct * 100).toStringAsFixed(0)}% D'),
                  _WDLLabel(color: AppColors.wrong,   label: '${(losePct * 100).toStringAsFixed(0)}% L'),
                ]),
              ],
            ]),
          ),
          const SizedBox(height: 24),

          // ── AC Coin Records ───────────────────────────────────────────────
          const SectionHeader(title: 'AC Coin Records  🪙'),
          const SizedBox(height: 14),

          Row(children: [
            Expanded(child: _StatTile(
              label: 'Best Single Win',
              value: '+${stats.hseWon} AC',
              icon:  Icons.trending_up_rounded,
              color: AppColors.correct,
            )),
            const SizedBox(width: 10),
            Expanded(child: _StatTile(
              label: 'Worst Single Loss',
              value: '−${stats.hseLost} AC',
              icon:  Icons.trending_down_rounded,
              color: AppColors.wrong,
            )),
          ]),
          const SizedBox(height: 10),
          _StatTile(
            label: 'Highest Stake',
            value: '${stats.hseStaked} AC',
            icon:  Icons.casino_rounded,
            color: AppColors.accent,
            wide:  true,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _WDLLabel extends StatelessWidget {
  final Color  color;
  final String label;
  const _WDLLabel({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700));
  }
}

// ─── Streak Shield Card ───────────────────────────────────────────────────────
class _StreakShieldCard extends StatelessWidget {
  final bool         active;
  final VoidCallback onBuy;
  const _StreakShieldCard({required this.active, required this.onBuy});

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.correct : AppColors.secondary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(color: color.withOpacity(0.14), shape: BoxShape.circle),
          child: Center(
            child: Text('🛡', style: TextStyle(fontSize: active ? 26 : 22)),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              active ? 'Streak Shield Active' : 'Streak Shield',
              style: TextStyle(
                color: active ? AppColors.correct : AppColors.textPrimary,
                fontSize: 15, fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              active
                  ? 'Your next missed day will be forgiven automatically.'
                  : 'Protect your streak against one missed day  —  30🪙',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.4),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        if (active)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color:        AppColors.correct.withOpacity(0.14),
              borderRadius: BorderRadius.circular(10),
              border:       Border.all(color: AppColors.correct.withOpacity(0.35)),
            ),
            child: const Text('ON',
                style: TextStyle(color: AppColors.correct, fontSize: 12,
                    fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          )
        else
          GestureDetector(
            onTap: onBuy,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color:        AppColors.secondary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(10),
                border:       Border.all(color: AppColors.secondary.withOpacity(0.40)),
              ),
              child: const Text('Activate',
                  style: TextStyle(color: AppColors.secondary, fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
  }
}

// ─── Reusable stat widgets ────────────────────────────────────────────────────
class _BigStatCard extends StatelessWidget {
  final String   value;
  final String   label;
  final IconData icon;
  final Color    color;
  const _BigStatCard({required this.value, required this.label,
      required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: color.withOpacity(0.30)),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
      ]),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String   label;
  final String   value;
  final IconData icon;
  final Color    color;
  final bool     wide;
  const _StatTile({required this.label, required this.value,
      required this.icon, required this.color, this.wide = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(label,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13))),
        Text(value,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

// ─── Achievements Tab ─────────────────────────────────────────────────────────
class _AchievementsTab extends StatelessWidget {
  const _AchievementsTab();

  @override
  Widget build(BuildContext context) {
    final p = context.watch<PlayerStatisticsProvider>();

    final achievements = [
      _Achievement(
        'Victory Road',
        'Win 50 games',
        p.won50Games,
        Icons.emoji_events_rounded,
        AppColors.correct,
      ),
      _Achievement(
        'Resilient',
        'Lose 50 games',
        p.lost50Games,
        Icons.shield_rounded,
        AppColors.secondary,
      ),
      _Achievement(
        'Centurion',
        'Play 100 games',
        p.played100Games,
        Icons.sports_esports_rounded,
        AppColors.accent,
      ),
      _Achievement(
        'High Roller',
        'Stake 500+ AC in a single match',
        p.staked500AC,
        Icons.casino_rounded,
        AppColors.primary,
      ),
      _Achievement(
        'Big Winner',
        'Win 1,000+ AC in a single match',
        p.won1000AC,
        Icons.trending_up_rounded,
        AppColors.correct,
      ),
    ];

    final unlocked = achievements.where((a) => a.achieved).length;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Progress summary card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: AppDecorations.card,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '$unlocked / ${achievements.length} Unlocked',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: achievements.isNotEmpty
                        ? unlocked / achievements.length
                        : 0.0,
                    backgroundColor: AppColors.divider,
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                    minHeight: 7,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  unlocked == achievements.length
                      ? '🏆 All achievements unlocked!'
                      : '${achievements.length - unlocked} remaining',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ]),
            ),
            const SizedBox(width: 14),
            const Icon(Icons.emoji_events_rounded, color: AppColors.accent, size: 34),
          ]),
        ),
        const SizedBox(height: 16),

        ...achievements.map((a) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _AchievementCard(item: a),
        )),
      ],
    );
  }
}

class _Achievement {
  final String   title;
  final String   desc;
  final bool     achieved;
  final IconData icon;
  final Color    color;
  const _Achievement(this.title, this.desc, this.achieved, this.icon, this.color);
}

class _AchievementCard extends StatelessWidget {
  final _Achievement item;
  const _AchievementCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = item.achieved ? item.color : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        item.achieved ? item.color.withOpacity(0.08) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: item.achieved ? item.color.withOpacity(0.35) : AppColors.divider,
        ),
      ),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
          child: Icon(item.icon, color: color, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(item.desc,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ]),
        ),
        Icon(
          item.achieved
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: color,
          size: 22,
        ),
      ]),
    );
  }
}

// ─── History Tab ──────────────────────────────────────────────────────────────
class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: FirestoreService.instance.matchHistoryStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }

        final matches = snap.data ?? [];

        if (matches.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history_rounded,
                    size: 64, color: AppColors.textMuted.withOpacity(0.5)),
                const SizedBox(height: 16),
                const Text('No match history yet',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 16)),
                const SizedBox(height: 6),
                const Text(
                  'Play a multiplayer game to see your history here',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: matches.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _HistoryCard(match: matches[i]),
        );
      },
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final Map<String, dynamic> match;
  const _HistoryCard({required this.match});

  // FIX: safely read numeric fields — Firestore can store ints as doubles,
  // causing "type 'double' is not a subtype of type 'int'" at runtime.
  static int _int(dynamic v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final outcome       = match['outcome']       as String? ?? 'lose';
    final opponent      = match['opponent']      as String? ?? 'Unknown';
    final playerScore   = _int(match['playerScore']);
    final opponentScore = _int(match['opponentScore']);
    final stakeAmount   = _int(match['stakeAmount']);
    final pointsChange  = _int(match['pointsChange']);
    final isQuickMatch  = match['isQuickMatch']  as bool?   ?? false;
    final animeTitle    = match['animeTitle']    as String? ?? '';
    final timestamp     = match['timestamp'];

    // ── Derive AC delta ──────────────────────────────────────────────────────
    // QM:           win=+35 AC, draw=+15 AC, lose=0 AC
    // Staked async: win=+floor(stake*0.8), draw=-floor(stake*0.05), lose=-stake
    // Legacy/zero stake: fall back to stored pointsChange
    final int acDelta;
    if (isQuickMatch) {
      acDelta = outcome == 'win' ? 35 : outcome == 'draw' ? 15 : 0;
    } else if (stakeAmount > 0) {
      if (outcome == 'win') {
        acDelta = (stakeAmount * 0.8).floor();
      } else if (outcome == 'draw') {
        acDelta = -(stakeAmount * 0.05).floor();
      } else {
        acDelta = -stakeAmount;
      }
    } else {
      acDelta = pointsChange;
    }

    final Color    color;
    final String   outLabel;
    final IconData outIcon;
    switch (outcome) {
      case 'win':
        color    = AppColors.correct;
        outLabel = 'Win';
        outIcon  = Icons.emoji_events_rounded;
      case 'draw':
        color    = AppColors.accent;
        outLabel = 'Draw';
        outIcon  = Icons.handshake_rounded;
      default:
        color    = AppColors.wrong;
        outLabel = 'Loss';
        outIcon  = Icons.close_rounded;
    }

    // ── Relative timestamp ───────────────────────────────────────────────────
    String timeStr = '';
    if (timestamp != null) {
      try {
        final dt   = (timestamp as dynamic).toDate() as DateTime;
        final diff = DateTime.now().difference(dt);
        if (diff.inMinutes < 60) {
          timeStr = '${diff.inMinutes}m ago';
        } else if (diff.inHours < 24) {
          timeStr = '${diff.inHours}h ago';
        } else {
          timeStr = '${diff.inDays}d ago';
        }
      } catch (_) {}
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(children: [
        // Outcome icon bubble
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
          child: Icon(outIcon, color: color, size: 22),
        ),
        const SizedBox(width: 12),

        // Info column
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Opponent + match-type badge row
            Row(children: [
              Text(outLabel,
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
              const Text(' vs ',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              Flexible(
                child: Text(opponent,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 6),
              // QM ⚡ or Async ⚔️ badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isQuickMatch
                      ? AppColors.primary.withOpacity(0.15)
                      : AppColors.secondary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isQuickMatch ? '⚡ QM' : '⚔️',
                  style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700,
                    color: isQuickMatch ? AppColors.primary : AppColors.secondary,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 3),

            // Score line + anime title
            Text(
              '$playerScore – $opponentScore'
              '${animeTitle.isNotEmpty ? "  •  $animeTitle" : ""}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),

            // Stake line (async challenges only)
            if (!isQuickMatch && stakeAmount > 0) ...[
              const SizedBox(height: 2),
              Text('🪙 $stakeAmount AC staked',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
            ],
          ],
        )),

        // AC delta column
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('🪙', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 2),
            Text(
              acDelta >= 0 ? '+$acDelta' : '$acDelta',
              style: TextStyle(
                color: acDelta > 0
                    ? AppColors.correct
                    : acDelta < 0
                        ? AppColors.wrong
                        : AppColors.textMuted,
                fontSize: 15, fontWeight: FontWeight.w800,
              ),
            ),
          ]),
          if (timeStr.isNotEmpty)
            Text(timeStr,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        ]),
      ]),
    );
  }
}