// lib/features/leaderboard/widgets/friends_board_tab.dart
//
// "Friends" tab: my friends + me, ordered by weeklyPoints.
//
// Data comes from the getFriendsBoard callable (no mirrors, zero writes),
// cached 6h client-side and re-read on the page's existing refresh cadence —
// no listeners, no new timers. The signed-in player's own row stays live from
// UserDataProvider (0 extra reads), matching the Global tab convention.
// Non-entrant friends (weeklyPoints null) render "-" and sort last.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/user_data_provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../multiplayer/rivalry_page.dart';
import 'leaderboard_rows.dart';
import 'leaderboard_states.dart';

class FriendsBoardTab extends StatelessWidget {
  final Future<FriendsBoardData> friendsFuture;
  final Future<void> Function() onRetry;
  final VoidCallback onAddFriend;

  const FriendsBoardTab({
    super.key,
    required this.friendsFuture,
    required this.onRetry,
    required this.onAddFriend,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FriendsBoardData>(
      future: friendsFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return BoardErrorState(error: snap.error, onRetry: () => onRetry());
        }
        if (!snap.hasData) return const BoardSpinner();
        final data = snap.data!;
        // A null fetchedAt means the fetch failed (service degrades to
        // empty); surface retry rather than a misleading "no friends".
        if (data.fetchedAt == null) {
          return BoardErrorState(
            error: 'Could not load friends.',
            onRetry: () => onRetry(),
          );
        }
        return _FriendsBody(
          data: data,
          onAddFriend: onAddFriend,
        );
      },
    );
  }
}

class _FriendsBody extends StatelessWidget {
  final FriendsBoardData data;
  final VoidCallback onAddFriend;

  const _FriendsBody({required this.data, required this.onAddFriend});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<UserDataProvider>();
    final myPoints = provider.weeklyPoints;
    final myName = _displayName(provider);

    final rows = data.friends.toList()
      ..sort((a, b) =>
          (b.weeklyPoints ?? -1).compareTo(a.weeklyPoints ?? -1));

    if (rows.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 32.r, vertical: 24.r),
          child: AppEmptyState(
            icon: Icons.people_outline_rounded,
            title: 'No friends yet',
            message: 'Add friends to race them here.',
            action: ElevatedButton(
              onPressed: onAddFriend,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Add Friend'),
            ),
          ),
        ),
      );
    }

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
            child: _MeRow(name: myName, points: myPoints),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20.r, 20.r, 20.r, 12.r),
            child: LeaderboardSectionHeader(
              icon: Icons.people_rounded,
              title: 'Friends',
              color: AppColors.primary,
              trailing:
                  '${rows.length} friend${rows.length == 1 ? '' : 's'}',
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 24.r),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final f = rows[i];
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: i == rows.length - 1 ? 0 : 8.r,
                  ),
                  child: _FriendRow(
                    entry: f,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RivalryPage(
                          rivalUid: f.uid,
                          rivalUsername: f.username,
                        ),
                      ),
                    ),
                  ),
                );
              },
              childCount: rows.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 32.r),
            child: BoardFooter(
              shown: rows.length,
              totalPlayers: rows.length,
              fetchedAt: data.fetchedAt,
            ),
          ),
        ),
      ],
    );
  }

  static String _displayName(UserDataProvider provider) {
    // UserDataProvider exposes weeklyPoints/premium; the display name comes
    // from the auth profile via FutureBuilder-free read is unavailable, so
    // fall back to 'You' — the row's purpose is the live points figure.
    return 'You';
  }
}

class _MeRow extends StatelessWidget {
  final String name;
  final int points;
  const _MeRow({required this.name, required this.points});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14.r),
        border:
            Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 40.w,
            height: 40.h,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt_rounded,
                  color: AppColors.accent, size: 12.r),
              SizedBox(width: 4.w),
              Text(
                '$points pts · live',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12.sp,
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

class _FriendRow extends StatelessWidget {
  final FriendBoardEntry entry;
  final VoidCallback onTap;
  const _FriendRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pts = entry.weeklyPoints;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 38.w,
              height: 38.h,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: Text(
                entry.username.isEmpty
                    ? '?'
                    : entry.username[0].toUpperCase(),
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 17.sp,
                  fontWeight: FontWeight.w900,
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
                    entry.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (entry.university.isNotEmpty) ...[
                    SizedBox(height: 2.h),
                    Text(
                      entry.university,
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
            SizedBox(width: 8.w),
            Text(
              pts == null ? '−' : '$pts pts',
              style: TextStyle(
                color: pts == null
                    ? AppColors.textMuted
                    : AppColors.textPrimary,
                fontSize: 13.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(width: 8.w),
            _NudgeButton(friendUid: entry.uid),
          ],
        ),
      ),
    );
  }
}

/// Preset "Your turn!" ping. The server finds the pair's latest their-turn
/// duel (or errors nothing_to_nudge / not_their_turn), enforces once per
/// friend per day, and sends the push. Preset text only — no free text.
class _NudgeButton extends StatefulWidget {
  final String friendUid;
  const _NudgeButton({required this.friendUid});

  @override
  State<_NudgeButton> createState() => _NudgeButtonState();
}

class _NudgeButtonState extends State<_NudgeButton> {
  bool _busy = false;
  bool _done = false;

  Future<void> _nudge() async {
    if (_busy || _done) return;
    setState(() => _busy = true);
    try {
      await FirestoreService.instance
          .nudgeFriend(friendUid: widget.friendUid);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nudge sent!'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final raw = e.toString().replaceFirst('Exception: ', '');
      final message = raw.contains('nudge_limit_reached')
          ? 'Already nudged today.'
          : raw.contains('nothing_to_nudge') ||
                  raw.contains('not_their_turn')
              ? 'Nothing needs them right now.'
              : raw.contains('not_friends')
                  ? 'You are no longer friends.'
                  : 'Could not nudge — try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: (_busy || _done) ? null : _nudge,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: (_done ? AppColors.textMuted : AppColors.secondary)
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(
            color: (_done ? AppColors.textMuted : AppColors.secondary)
                .withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          _done
              ? 'Nudged ✓'
              : _busy
                  ? '…'
                  : 'Nudge',
          style: TextStyle(
            color: _done ? AppColors.textMuted : AppColors.secondary,
            fontSize: 11.sp,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
