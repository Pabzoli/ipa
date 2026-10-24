// lib/features/leaderboard/widgets/friends_board_tab.dart
//
// "Friends" tab: the signed-in player and their friends, ranked by weekly
// points (see rankFriendsBoard). Friends where I owe a move are listed first.
//
// The board comes from the getFriendsBoard callable (no mirrors, zero writes).
// It is NOT on the global leaderboard's six-hour timer: it loads when the tab
// is opened, refetches when the tab becomes visible again, and supports
// pull-to-refresh, all floored by a five-minute service cache. The signed-in
// player's own points stay live from UserDataProvider. Friends with no entry
// this week show "–" and sort after the ranked rows.
//
// A row is a RANKING line, not a control panel: rank, avatar, name, one status
// line and the week's points, plus the nudge bell when the friend owes a move
// and a chevron to open the head-to-head page. The name is a target too, and
// the chevron is its affordance. Nothing else is tappable — challenging,
// removing or blocking a friend happens on that page, not in a ⋯ menu over the
// list.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/user_data_provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_page_route.dart';
import '../../friends/friend_nudge_button.dart';
import '../../friends/friend_ranking.dart';
import '../../friends/friend_widgets.dart';
import '../../multiplayer/rivalry_page.dart';
import 'leaderboard_rows.dart';
import 'leaderboard_states.dart';

class FriendsBoardTab extends StatelessWidget {
  /// Null until the first board request; shows a spinner in the meantime.
  final Future<FriendsBoardData>? friendsFuture;

  /// Force-refreshes the board and completes when the new data lands. Shared by
  /// the error state's "Try again", the pull-to-refresh gesture and a friend
  /// page that changed the friendship.
  final Future<void> Function() onReload;

  final VoidCallback onAddFriend;

  const FriendsBoardTab({
    super.key,
    required this.friendsFuture,
    required this.onReload,
    required this.onAddFriend,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FriendsBoardData>(
      future: friendsFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return BoardErrorState(
            error: snap.error,
            onRetry: () {
              onReload();
            },
          );
        }
        if (!snap.hasData) return const BoardSpinner();
        final data = snap.data!;
        // A null fetchedAt means the fetch failed (service degrades to
        // empty); surface retry rather than a misleading "no friends".
        if (data.fetchedAt == null) {
          return BoardErrorState(
            error: 'Could not load friends.',
            onRetry: () {
              onReload();
            },
          );
        }
        return RefreshIndicator(
          color: AppColors.primary,
          backgroundColor: AppColors.surface,
          onRefresh: onReload,
          child: _FriendsBody(
            data: data,
            onAddFriend: onAddFriend,
            onChanged: onReload,
          ),
        );
      },
    );
  }
}

class _FriendsBody extends StatelessWidget {
  final FriendsBoardData data;
  final VoidCallback onAddFriend;
  final Future<void> Function() onChanged;

  const _FriendsBody({
    required this.data,
    required this.onAddFriend,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final myPoints = context.watch<UserDataProvider>().weeklyPoints;
    final rows = rankFriendsBoard(friends: data.friends, myPoints: myPoints);
    final me = rows.firstWhere((r) => r.isMe);
    final friendRows = rows.where((r) => !r.isMe).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.lg,
        AppSpacing.page,
        AppSpacing.xxl,
      ),
      children: [
        _MeRow(name: me.name, rank: me.rank, points: me.points),
        SizedBox(height: AppSpacing.lg),
        FriendSectionTitle(
          title: 'Friends',
          count: friendRows.length,
          // The empty state carries its own "Add friend" button, so the header
          // only offers it once there is a list to add to.
          trailing: friendRows.isEmpty
              ? null
              : FriendActionChip(
                  label: 'Add',
                  icon: Icons.person_add_alt_1_rounded,
                  color: AppColors.primary,
                  onPressed: onAddFriend,
                ),
        ),
        SizedBox(height: AppSpacing.sm),
        if (friendRows.isEmpty)
          _EmptyFriends(onAddFriend: onAddFriend)
        else
          for (final row in friendRows)
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: _FriendRow(row: row, onChanged: onChanged),
            ),
        SizedBox(height: AppSpacing.lg),
        BoardFooter(
          fetchedAt: data.fetchedAt,
          subtitle: data.fetchedAt == null
              ? 'Updating…'
              : 'Updated ${_clockTime(data.fetchedAt!)}',
        ),
      ],
    );
  }

  static String _clockTime(DateTime at) {
    final local = at.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// The signed-in player's own line. Same shape as a friend row, without any
/// action: there is nothing to do to yourself.
class _MeRow extends StatelessWidget {
  final String name;
  final int? rank;
  final int? points;

  const _MeRow({required this.name, required this.rank, required this.points});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      color: AppColors.primarySoft,
      borderColor: AppColors.primaryBorder,
      child: Row(
        children: [
          RankBadge(rank: rank),
          SizedBox(width: 10.w),
          AppAvatar(label: friendInitial(name), size: 36.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.labelLarge,
                ),
              ],
            ),
          ),
          SizedBox(width: 8.w),
          _PointsText(points: points),
        ],
      ),
    );
  }
}

class _EmptyFriends extends StatelessWidget {
  final VoidCallback onAddFriend;
  const _EmptyFriends({required this.onAddFriend});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.people_outline_rounded,
      title: 'No friends yet',
      action: AppButton(
        label: 'Add friend',
        size: AppButtonSize.small,
        onPressed: onAddFriend,
      ),
    );
  }
}

/// The week's points: the number leads, the unit stays quiet.
class _PointsText extends StatelessWidget {
  final int? points;
  const _PointsText({required this.points});

  @override
  Widget build(BuildContext context) {
    final p = points;
    final ranked = p != null;
    return Text.rich(
      TextSpan(
        text: ranked ? '$p' : '–',
        style: AppTypography.labelLarge.copyWith(
          fontWeight: FontWeight.w900,
          color: ranked ? AppColors.textPrimary : AppColors.textMuted,
        ),
        children: [
          if (ranked)
            TextSpan(
              text: ' pts',
              style: AppTypography.labelSmall.copyWith(
                color: AppColors.textMuted,
                letterSpacing: 0,
              ),
            ),
        ],
      ),
    );
  }
}

/// One status line, in priority order: what the player can act on first.
class _StatusLine extends StatelessWidget {
  final FriendRankRow row;

  const _StatusLine({required this.row});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _status();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5.r,
          height: 5.r,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: 5.w),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodySmall.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  (String, Color) _status() {
    if (row.myTurn) return ('Your move', AppColors.primary);
    if (row.theirTurn) {
      return row.nudgedToday
          ? ('Nudged today', AppColors.secondary)
          : ('Their move', AppColors.secondary);
    }
    if (row.playedToday) return ('Played today', AppColors.correct);
    if (row.points == null) return ('No entry this week', AppColors.textMuted);
    if (row.subtitle.isNotEmpty) return (row.subtitle, AppColors.textMuted);
    return ('Ready for a spar', AppColors.textMuted);
  }
}

class _FriendRow extends StatelessWidget {
  final FriendRankRow row;
  final Future<void> Function() onChanged;

  const _FriendRow({required this.row, required this.onChanged});

  /// Opens the head-to-head page, which is also where a friendship is removed
  /// or blocked. Returns true from there when the friendship changed.
  Future<void> _openFriend(BuildContext context) async {
    final changed = await Navigator.of(context).push<bool>(
      AppPageRoute(
        builder: (_) => RivalryPage(
          rivalUid: row.uid,
          rivalUsername: row.name,
          isFriend: true,
        ),
      ),
    );
    if (changed == true) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.fromLTRB(12.r, 10.r, 8.r, 10.r),
      // A friend waiting on me is the one row worth lifting off the page.
      borderColor: row.myTurn ? AppColors.primaryBorder : null,
      child: Row(
        children: [
          RankBadge(rank: row.rank),
          SizedBox(width: 10.w),
          AppAvatar(label: friendInitial(row.name), size: 36.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The name is the target that opens this friend's page, and
                // the chevron says so. Only this and the chevron are tappable:
                // the rank, the status and the points are information, so a
                // tap on them does nothing instead of opening something the
                // player did not aim at.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openFriend(context),
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.labelLarge,
                  ),
                ),
                SizedBox(height: 2.h),
                _StatusLine(row: row),
              ],
            ),
          ),
          SizedBox(width: 8.w),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              _PointsText(points: row.points),
              // The only inline action left: nudge the friend who owes a move.
              // Challenging them is one tap away on their page.
              if (row.theirTurn) ...[
                SizedBox(height: 4.h),
                FriendNudgeButton(friendUid: row.uid, iconOnly: true),
              ],
            ],
          ),
          IconButton(
            tooltip: 'Head-to-head',
            onPressed: () => _openFriend(context),
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: 32.r, height: 40.r),
            icon: Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textMuted,
              size: 20.r,
            ),
          ),
        ],
      ),
    );
  }
}
