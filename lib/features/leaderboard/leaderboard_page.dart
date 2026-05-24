import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/firestore_service.dart';

class LeaderboardPage extends StatelessWidget {
  const LeaderboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              // ── App bar ─────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: AppColors.textPrimary),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text(
                      'Leaderboard',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.correct.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppColors.correct.withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: AppColors.correct,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const Text('LIVE',
                              style: TextStyle(
                                  color: AppColors.correct,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: FirestoreService.instance.leaderboardStream(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary),
                      );
                    }

                    if (snap.hasError) {
                      return _ErrorView(
                          message: snap.error.toString());
                    }

                    final entries = snap.data ?? [];

                    if (entries.isEmpty) {
                      return const Center(
                        child: Text('No players yet!',
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 16)),
                      );
                    }

                    // Top 3 for podium, rest for list
                    final podium = entries.take(3).toList();
                    final rest   = entries.skip(3).toList();

                    // Find current user anywhere in the list
                    Map<String, dynamic>? myEntry;
                    for (final e in entries) {
                      if (e['isCurrentUser'] == true) {
                        myEntry = e;
                        break;
                      }
                    }

                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(20, 20, 20, 8),
                            child: _Podium(entries: podium),
                          ),
                        ),

                        // My rank banner — only if outside top 3
                        if (myEntry != null &&
                            (myEntry['rank'] as int? ?? 0) > 3)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 4, 20, 4),
                              child: _MyRankBanner(entry: myEntry),
                            ),
                          ),

                        SliverPadding(
                          padding:
                              const EdgeInsets.fromLTRB(20, 8, 20, 32),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (_, i) => _LeaderRow(entry: rest[i]),
                              childCount: rest.length,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Podium ───────────────────────────────────────────────────────────────────
// Classic podium layout: 2nd (left) | 1st (centre, tallest) | 3rd (right)
class _Podium extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  const _Podium({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();

    // We always want centre = rank 1, left = rank 2, right = rank 3.
    // Build slots in display order [2nd, 1st, 3rd].
    final Map<int, Map<String, dynamic>> byRank = {};
    for (final e in entries) {
      byRank[e['rank'] as int] = e;
    }

    // Slot definitions: [left=2nd, centre=1st, right=3rd]
    final slots = [
      byRank[2],
      byRank[1],
      byRank[3],
    ];

    // Podium block heights and avatar sizes per slot (left, centre, right)
    const blockHeights = [85.0, 120.0, 65.0];
    const avatarSizes  = [52.0,  68.0, 46.0];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      decoration: AppDecorations.card,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(slots.length, (i) {
          final entry = slots[i];
          if (entry == null) return const Expanded(child: SizedBox());

          final rank      = entry['rank'] as int;
          final name      = entry['username'] as String? ?? '?';
          final score     = entry['totalScore'] as int? ?? 0;
          final isMe      = entry['isCurrentUser'] == true;
          final blockH    = blockHeights[i];
          final avatarSz  = avatarSizes[i];
          final isFirst   = rank == 1;

          return Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Crown above 1st place only
                if (isFirst)
                  const Text('👑', style: TextStyle(fontSize: 24))
                else
                  const SizedBox(height: 30),
                const SizedBox(height: 4),

                // Avatar circle
                Container(
                  width: avatarSz,
                  height: avatarSz,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _medalColors(rank),
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    border: isMe
                        ? Border.all(color: AppColors.primary, width: 2.5)
                        : null,
                    boxShadow: [
                      BoxShadow(
                        color: _medalColors(rank).first.withOpacity(0.4),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      name.isNotEmpty
                          ? name.substring(0, 1).toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: avatarSz * 0.38,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                // Name
                Text(
                  name,
                  style: TextStyle(
                    color:
                        isMe ? AppColors.primary : AppColors.textPrimary,
                    fontSize: isFirst ? 13 : 11,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),

                // Score
                Text(
                  '$score pts',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 10),
                ),
                const SizedBox(height: 6),

                // Podium block
                Container(
                  height: blockH,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _medalColors(rank).first.withOpacity(0.35),
                        _medalColors(rank).first.withOpacity(0.1),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(10)),
                    border: Border.all(
                      color: _medalColors(rank).first.withOpacity(0.3),
                    ),
                  ),
                  child: Center(
                    child: Text(
                      _medalEmoji(rank),
                      style: TextStyle(
                          fontSize: isFirst ? 26 : 20),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  List<Color> _medalColors(int rank) {
    switch (rank) {
      case 1:  return [const Color(0xFFFFD700), const Color(0xFFFFA500)];
      case 2:  return [const Color(0xFFC0C0C0), const Color(0xFF909090)];
      case 3:  return [const Color(0xFFCD7F32), const Color(0xFF8B4513)];
      default: return [AppColors.secondary, AppColors.surfaceAlt];
    }
  }

  String _medalEmoji(int rank) {
    switch (rank) {
      case 1:  return '🥇';
      case 2:  return '🥈';
      case 3:  return '🥉';
      default: return '#$rank';
    }
  }
}

// ─── My Rank Banner ───────────────────────────────────────────────────────────
class _MyRankBanner extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _MyRankBanner({required this.entry});

  @override
  Widget build(BuildContext context) {
    final rank  = entry['rank']       as int? ?? 0;
    final score = entry['totalScore'] as int? ?? 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: AppColors.primary.withOpacity(0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.person_rounded,
            color: AppColors.primary, size: 18),
        const SizedBox(width: 8),
        const Text('Your rank',
            style: TextStyle(
                color: AppColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('#$rank',
            style: const TextStyle(
                color: AppColors.primary,
                fontSize: 18,
                fontWeight: FontWeight.w900)),
        const SizedBox(width: 12),
        Text('$score pts',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 13)),
      ]),
    );
  }
}

// ─── Leader Row (rank 4+) ─────────────────────────────────────────────────────
class _LeaderRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _LeaderRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final rank  = entry['rank']           as int?    ?? 0;
    final name  = entry['username']       as String? ?? 'Unknown';
    final score = entry['totalScore']     as int?    ?? 0;
    final isMe  = entry['isCurrentUser']  == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isMe
            ? AppColors.primary.withOpacity(0.08)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isMe
              ? AppColors.primary.withOpacity(0.35)
              : AppColors.divider,
          width: isMe ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: Text(
            '#$rank',
            style: TextStyle(
              color: isMe ? AppColors.primary : AppColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isMe
                ? AppColors.primary.withOpacity(0.2)
                : AppColors.surfaceAlt,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
              style: TextStyle(
                color:
                    isMe ? AppColors.primary : AppColors.textSecondary,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            isMe ? '$name (You)' : name,
            style: TextStyle(
              color:
                  isMe ? AppColors.primary : AppColors.textPrimary,
              fontSize: 14,
              fontWeight: isMe ? FontWeight.w700 : FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          '$score pts',
          style: TextStyle(
            color: isMe ? AppColors.primary : AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ]),
    );
  }
}

// ─── Error View ───────────────────────────────────────────────────────────────
class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                color: AppColors.wrong, size: 48),
            const SizedBox(height: 16),
            Text(message,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 14),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
