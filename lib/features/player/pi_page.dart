import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';    // FIX: added
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
  String _username = 'Trainer';
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

  // ── SPEND SURFACE 6: Streak Shield (30 AC) ──────────────────────────────────
  // FIX: new method called from the shield card in _StatisticsTab.

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
      await userData.updateAnimeCoins(-cost, 'spend_shield');
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
  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Something went wrong — please try again.')),
  );
}
  }

  @override
  Widget build(BuildContext context) {
    final stats      = context.watch<PlayerStatisticsProvider>().playerStatistics;
    final totalScore = context.watch<UserDataProvider>().score;
    // FIX: read shield state here so _StatisticsTab stays a StatelessWidget
    final shieldActive = context.watch<UserDataProvider>().streakShieldActive;

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
                username:    _usernameLoading ? '...' : _username,
                totalScore:  totalScore,
                onEditName:  () => _showEditUsername(context),
              ),
            ),
            bottom: TabBar(
              controller: _tabCtrl,
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
            // FIX: pass shield props so the Statistics tab can render the card
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
                child: const Text('OK')),
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
                  width: 18,
                  height: 18,
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
  final int      totalScore;
  final VoidCallback onEditName;

  const _ProfileHeader({
    required this.username,
    required this.totalScore,
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
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, Color(0xFFFF6B6B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.4),
                  blurRadius: 16,
                ),
              ],
            ),
            child: const Icon(Icons.person_rounded, color: Colors.white, size: 42),
          ),
          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
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

                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.accent.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.stars_rounded,
                          color: AppColors.accent, size: 15),
                      const SizedBox(width: 5),
                      Text(
                        '$totalScore pts',
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ],
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

// ─── Statistics Tab ───────────────────────────────────────────────────────────
// FIX: added [shieldActive] and [onBuyShield] so Surface 6 can be rendered
// without converting this widget to a StatefulWidget or reading the provider
// directly (which would require a BuildContext with a Provider ancestor, which
// NestedScrollView's TabBarView always has — but passing props is cleaner).
class _StatisticsTab extends StatelessWidget {
  final PlayerStatistics stats;
  final bool             shieldActive;   // FIX: new
  final VoidCallback     onBuyShield;    // FIX: new

  const _StatisticsTab({
    required this.stats,
    required this.shieldActive,
    required this.onBuyShield,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── SPEND SURFACE 6: Streak Shield card ───────────────────────────
          // FIX: entire card is new. Shows active state or the buy button.
          _StreakShieldCard(
            active:     shieldActive,
            onBuy:      onBuyShield,
          ),
          const SizedBox(height: 24),

          // ── Match Summary Cards ────────────────────────────────────────────
          const SectionHeader(title: 'Match Record'),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(child: _BigStatCard(
                value: '${stats.gamesWon}',
                label: 'Wins',
                icon: Icons.emoji_events_rounded,
                color: AppColors.correct,
              )),
              const SizedBox(width: 10),
              Expanded(child: _BigStatCard(
                value: '${stats.gamesDraw}',
                label: 'Draws',
                icon: Icons.handshake_rounded,
                color: AppColors.accent,
              )),
              const SizedBox(width: 10),
              Expanded(child: _BigStatCard(
                value: '${stats.gamesLost}',
                label: 'Losses',
                icon: Icons.close_rounded,
                color: AppColors.wrong,
              )),
            ],
          ),
          const SizedBox(height: 12),

          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(children: [
              const Icon(Icons.sports_esports_rounded,
                  color: AppColors.secondary, size: 22),
              const SizedBox(width: 12),
              const Text('Games Played',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 15)),
              const Spacer(),
              Text('${stats.gamesPlayed}',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w900)),
            ]),
          ),

          if (stats.gamesPlayed > 0) ...[
            const SizedBox(height: 12),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Win Rate',
                          style: TextStyle(color: AppColors.textSecondary)),
                      Text(
                        '${(stats.gamesWon / stats.gamesPlayed * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                            color: AppColors.correct,
                            fontWeight: FontWeight.w800,
                            fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: stats.gamesWon / stats.gamesPlayed,
                      backgroundColor: AppColors.divider,
                      valueColor:
                          const AlwaysStoppedAnimation(AppColors.correct),
                      minHeight: 8,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),
          const SectionHeader(title: 'Betting Records'),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _StatTile(
              label: 'Biggest Win',
              value: '${stats.hseWon}',
              icon: Icons.trending_up_rounded,
              color: AppColors.correct,
            )),
            const SizedBox(width: 10),
            Expanded(child: _StatTile(
              label: 'Worst Loss',
              value: '${stats.hseLost}',
              icon: Icons.trending_down_rounded,
              color: AppColors.wrong,
            )),
          ]),
          const SizedBox(height: 10),
          _StatTile(
            label: 'Highest Bet',
            value: '${stats.hseStaked}',
            icon: Icons.casino_rounded,
            color: AppColors.accent,
            wide: true,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Streak Shield Card (SPEND SURFACE 6) ────────────────────────────────────
// FIX: new widget. Placed at the top of _StatisticsTab.
// Shows shield status when active, or the "buy" button when inactive.
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
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(
        children: [
          Container(
            width:  48,
            height: 48,
            decoration: BoxDecoration(
              color:  color.withOpacity(0.14),
              shape:  BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '🛡',
                style: TextStyle(
                  fontSize: active ? 26 : 22,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active ? 'Streak Shield Active' : 'Streak Shield',
                  style: TextStyle(
                    color:      active ? AppColors.correct : AppColors.textPrimary,
                    fontSize:   15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  active
                      ? 'Your next missed day will be forgiven automatically.'
                      : 'Protect your streak against one missed day  —  30🪙',
                  style: const TextStyle(
                    color:    AppColors.textMuted,
                    fontSize: 12,
                    height:   1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color:        AppColors.correct.withOpacity(0.14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.correct.withOpacity(0.35)),
              ),
              child: const Text(
                'ON',
                style: TextStyle(
                  color:      AppColors.correct,
                  fontSize:   12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            )
          else
            GestureDetector(
              onTap: onBuy,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color:        AppColors.secondary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.secondary.withOpacity(0.40)),
                ),
                child: const Text(
                  'Activate',
                  style: TextStyle(
                    color:      AppColors.secondary,
                    fontSize:   13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BigStatCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color color;
  const _BigStatCard({required this.value, required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 26, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
      ]),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool wide;
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(label,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 13))),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 18, fontWeight: FontWeight.w800)),
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
      _Achievement('Win Streak',  'Win 50 games',    p.won50Games,    Icons.emoji_events_rounded, AppColors.correct),
      _Achievement('Resilient',   'Lose 50 games',   p.lost50Games,   Icons.shield_rounded,       AppColors.secondary),
      _Achievement('Centurion',   'Play 100 games',  p.played100Games, Icons.sports_esports_rounded, AppColors.accent),
      _Achievement('High Roller', 'Win 5,000 pts',   p.won5000Score,  Icons.casino_rounded,       AppColors.correct),
      _Achievement('Risk Taker',  'Lose 2,500 pts',  p.lost2500Score, Icons.whatshot_rounded,     AppColors.wrong),
    ];

    final unlocked = achievements.where((a) => a.achieved).length;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: AppDecorations.card,
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$unlocked / ${achievements.length} Unlocked',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: unlocked / achievements.length,
                  backgroundColor: AppColors.divider,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.accent),
                  minHeight: 6,
                ),
              ),
            ])),
            const SizedBox(width: 14),
            const Icon(Icons.emoji_events_rounded,
                color: AppColors.accent, size: 32),
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
        color: item.achieved ? item.color.withOpacity(0.08) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: item.achieved
              ? item.color.withOpacity(0.35)
              : AppColors.divider,
        ),
      ),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
              color: color.withOpacity(0.15), shape: BoxShape.circle),
          child: Icon(item.icon, color: color, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.title,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(item.desc,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
        ])),
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
                    size: 64,
                    color: AppColors.textMuted.withOpacity(0.5)),
                const SizedBox(height: 16),
                const Text('No match history yet',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 16)),
                const SizedBox(height: 6),
                const Text(
                  'Play a multiplayer game to see your history here',
                  style:
                      TextStyle(color: AppColors.textMuted, fontSize: 13),
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

  @override
  Widget build(BuildContext context) {
    final outcome      = match['outcome'] as String? ?? 'lose';
    final opponent     = match['opponent'] as String? ?? 'Unknown';
    final playerScore  = match['playerScore'] as int? ?? 0;
    final opponentScore = match['opponentScore'] as int? ?? 0;
    final betScore     = match['betScore'] as int? ?? 0;
    final pointsChange = match['pointsChange'] as int? ?? 0;
    final timestamp    = match['timestamp'];

    final Color color;
    final String outLabel;
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

    String timeStr = '';
    if (timestamp != null) {
      try {
        final dt = (timestamp as dynamic).toDate() as DateTime;
        final now = DateTime.now();
        final diff = now.difference(dt);
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
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: color.withOpacity(0.15), shape: BoxShape.circle),
          child: Icon(outIcon, color: color, size: 22),
        ),
        const SizedBox(width: 12),

        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(outLabel,
                style: TextStyle(
                    color: color, fontSize: 13, fontWeight: FontWeight.w700)),
            const Text(' vs ',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            Flexible(child: Text(opponent,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 4),
          Text('$playerScore – $opponentScore  •  Bet: $betScore pts',
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 11)),
        ])),

        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
            pointsChange >= 0 ? '+$pointsChange' : '$pointsChange',
            style: TextStyle(
                color: pointsChange >= 0 ? AppColors.correct : AppColors.wrong,
                fontSize: 15,
                fontWeight: FontWeight.w800),
          ),
          if (timeStr.isNotEmpty)
            Text(timeStr,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 11)),
        ]),
      ]),
    );
  }
}