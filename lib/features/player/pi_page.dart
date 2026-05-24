import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../multiplayer/models/challenge_model.dart';
import '../multiplayer/challenge_lobby_page.dart';
import '../multiplayer/challenge_result_page.dart';
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

  @override
  Widget build(BuildContext context) {
    final stats      = context.watch<PlayerStatisticsProvider>().playerStatistics;
    final totalScore = context.watch<UserDataProvider>().score;

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
                Tab(text: 'Challenges'),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _StatisticsTab(stats: stats),
            const _AchievementsTab(),
            const _ChallengesTab(),
          ],
        ),
      ),
    );
  }

  void _showEditUsername(BuildContext context) async {
    // Check if user can change
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
          // ── Icon badge (no avatar image) ──────────────────────────────────
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

          // ── Username + score ──────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Username row with edit button
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

                // Score badge
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
class _StatisticsTab extends StatelessWidget {
  final PlayerStatistics stats;
  const _StatisticsTab({required this.stats});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Match Summary Cards ────────────────────────────────────────────
          const SectionHeader(title: 'Match Record'),
          const SizedBox(height: 16),

          // Wins / Losses / Draws in a 3-column row
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

          // Games played
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

          // Win rate bar
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
        // Progress header
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
// ─── Challenges Tab ───────────────────────────────────────────────────────────
class _ChallengesTab extends StatefulWidget {
  const _ChallengesTab();

  @override
  State<_ChallengesTab> createState() => _ChallengesTabState();
}

class _ChallengesTabState extends State<_ChallengesTab>
    with SingleTickerProviderStateMixin {
  late final TabController                    _subTabCtrl;
  late final Stream<List<ChallengeModel>>     _activeStream;
  late final Stream<List<ChallengeModel>>     _allStream;

  @override
  void initState() {
    super.initState();
    _subTabCtrl   = TabController(length: 2, vsync: this);
    // Streams are created once here — never inside build().
    _activeStream = FirestoreService.instance.myChallengesStream(activeOnly: true);
    _allStream    = FirestoreService.instance.myChallengesStream(activeOnly: false);
  }

  @override
  void dispose() {
    _subTabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller:           _subTabCtrl,
          labelColor:           AppColors.primary,
          unselectedLabelColor: AppColors.textMuted,
          indicatorColor:       AppColors.primary,
          indicatorWeight:      2,
          dividerColor:         AppColors.divider,
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Completed'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _subTabCtrl,
            children: [
              _ChallengeFeed(stream: _activeStream, activeOnly: true),
              _ChallengeFeed(stream: _allStream,    activeOnly: false),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Challenge Feed ───────────────────────────────────────────────────────────
class _ChallengeFeed extends StatelessWidget {
  final Stream<List<ChallengeModel>> stream;
  final bool                         activeOnly;
  const _ChallengeFeed({required this.stream, required this.activeOnly});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ChallengeModel>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 48, color: AppColors.wrong.withOpacity(0.6)),
                const SizedBox(height: 12),
                const Text('Could not load challenges',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
              ],
            ),
          );
        }

        final all = snap.data ?? [];
        final challenges = activeOnly
            ? all.where((c) => c.isWaiting || c.isInProgress).toList()
            : all.where((c) => c.isComplete).toList();

        if (challenges.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    activeOnly
                        ? Icons.sports_kabaddi_rounded
                        : Icons.history_rounded,
                    size:  60,
                    color: AppColors.textMuted.withOpacity(0.4),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    activeOnly ? 'No active challenges' : 'No completed challenges',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    activeOnly
                        ? 'Create one from the home screen!'
                        : 'Finish a challenge to see it here.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          padding:          const EdgeInsets.fromLTRB(20, 16, 20, 32),
          itemCount:        challenges.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final c = challenges[i];
            return _ProfileChallengeCard(
              challenge: c,
              onTap:     () => _navigateToChallenge(context, c),
            );
          },
        );
      },
    );
  }

  void _navigateToChallenge(BuildContext context, ChallengeModel c) {
    final uid       = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = c.creatorUid == uid;
    final myScore   = isCreator ? (c.creatorScore ?? 0) : (c.opponentScore ?? 0);

    if (isCreator && !c.creatorHasPlayed && !c.isComplete) {
      Navigator.push(context,
        MaterialPageRoute(builder: (_) => ChallengeLobbyPage(challenge: c)));
      return;
    }

    Navigator.push(context,
      MaterialPageRoute(
        builder: (_) => ChallengeResultPage(
          challengeId: c.challengeId,
          challenge:   c,
          isCreator:   isCreator,
          myScore:     myScore,
        ),
      ));
  }
}

// ─── Profile Challenge Card ────────────────────────────────────────────────────
class _ProfileChallengeCard extends StatelessWidget {
  final ChallengeModel challenge;
  final VoidCallback   onTap;
  const _ProfileChallengeCard({required this.challenge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uid        = FirebaseAuth.instance.currentUser?.uid;
    final isCreator  = challenge.creatorUid == uid;
    final opponent   = isCreator
        ? (challenge.opponentUsername ?? 'Waiting for opponent…')
        : challenge.creatorUsername;
    final myScore    = isCreator ? challenge.creatorScore    : challenge.opponentScore;
    final theirScore = isCreator ? challenge.opponentScore   : challenge.creatorScore;

    final statusColor = _statusColor();
    final statusLabel = _statusLabel(isCreator);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:    const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: statusColor.withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Opponent + status ─────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  CircleAvatar(
                    radius:          18,
                    backgroundColor: AppColors.primary.withOpacity(0.12),
                    child: Text(
                      opponent[0].toUpperCase(),
                      style: const TextStyle(
                          color: AppColors.primary, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('vs $opponent',
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                    Text(challenge.animeTitle,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                  ]),
                ]),
                _ChallengeStatusBadge(label: statusLabel, color: statusColor),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(color: AppColors.divider, height: 1),
            const SizedBox(height: 12),

            // ── Scores + bet ──────────────────────────────────────────────────
            Row(children: [
              Expanded(child: _ChallengeScoreTile(
                label: 'You',
                score: myScore,
                total: challenge.questionIds.length,
              )),
              Container(width: 1, height: 36, color: AppColors.divider),
              Expanded(child: _ChallengeScoreTile(
                label:    opponent.split(' ').first,
                score:    theirScore,
                total:    challenge.questionIds.length,
                alignEnd: true,
              )),
              Container(width: 1, height: 36, color: AppColors.divider),
              Expanded(child: Column(children: [
                const Text('Bet',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
                Text('${challenge.betAmount}',
                    style: const TextStyle(
                        color:      AppColors.secondary,
                        fontWeight: FontWeight.w800,
                        fontSize:   16),
                    textAlign: TextAlign.center),
              ])),
            ]),

            // ── Outcome ribbon ────────────────────────────────────────────────
            if (challenge.isComplete) ...[
              const SizedBox(height: 10),
              _ChallengeOutcomeRibbon(challenge: challenge, isCreator: isCreator),
            ],

            // ── Expiry ────────────────────────────────────────────────────────
            if (!challenge.isComplete) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.timer_outlined,
                    color: AppColors.textMuted, size: 13),
                const SizedBox(width: 4),
                Text(challenge.expiryLabel,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusColor() {
    if (challenge.isComplete)   return AppColors.correct;
    if (challenge.isInProgress) return AppColors.secondary;
    return AppColors.primary;
  }

  String _statusLabel(bool isCreator) {
    if (challenge.isComplete) return 'Finished';
    if (challenge.isInProgress) {
      final uid        = FirebaseAuth.instance.currentUser?.uid;
      final iAmCreator = challenge.creatorUid == uid;
      if (iAmCreator  && !challenge.creatorHasPlayed)  return 'Your turn';
      if (!iAmCreator && !challenge.opponentHasPlayed) return 'Your turn';
      return 'Opponent playing';
    }
    return 'Waiting';
  }
}

// ─── Small reusable challenge widgets ─────────────────────────────────────────

class _ChallengeStatusBadge extends StatelessWidget {
  final String label;
  final Color  color;
  const _ChallengeStatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding:    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:        color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

class _ChallengeScoreTile extends StatelessWidget {
  final String label;
  final int?   score;
  final int    total;
  final bool   alignEnd;
  const _ChallengeScoreTile({
    required this.label,
    required this.score,
    required this.total,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            overflow: TextOverflow.ellipsis),
        Text(
          score != null ? '$score/$total' : '—',
          style: TextStyle(
            color:      score != null ? AppColors.textPrimary : AppColors.textMuted,
            fontWeight: FontWeight.w800,
            fontSize:   15,
          ),
          textAlign: alignEnd ? TextAlign.right : TextAlign.center,
        ),
      ]);
}

class _ChallengeOutcomeRibbon extends StatelessWidget {
  final ChallengeModel challenge;
  final bool           isCreator;
  const _ChallengeOutcomeRibbon(
      {required this.challenge, required this.isCreator});

  @override
  Widget build(BuildContext context) {
    final iWon  = challenge.outcome ==
        (isCreator ? ChallengeOutcome.creatorWins : ChallengeOutcome.opponentWins);
    final isDraw = challenge.outcome == ChallengeOutcome.draw;

    final color = iWon ? AppColors.correct : isDraw ? AppColors.secondary : AppColors.wrong;
    final label = iWon
        ? '🏆 You won +${challenge.betAmount} pts'
        : isDraw
            ? '🤝 Draw — bet refunded'
            : '💀 You lost −${challenge.betAmount} pts';

    return Container(
      width:      double.infinity,
      padding:    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}