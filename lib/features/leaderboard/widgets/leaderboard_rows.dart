import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/services/prize_pool_service.dart';
import '../../../core/theme/app_theme.dart';
import '../leaderboard_models.dart';
import 'leaderboard_pool_card.dart';

/// The top three, ordered strictly by rank.
///
/// Requires at least two entrants before it renders at all: with a single
/// entrant the old layout stretched one card across the full page width, which
/// read as a broken row rather than a podium.
///
/// Every ranked card that is not the signed-in player is tappable: tapping one
/// opens that player's page. [rivalUids] no longer controls tappability — it
/// only decides which card carries the RIVAL badge, and it names the single
/// player sitting directly above the signed-in player.
class LeaderboardPodium extends StatelessWidget {
  final List<BoardEntry> entries;

  /// Rank → prize, from the live projection.
  final Map<int, double> prizes;

  /// Entries that carry the RIVAL badge (the player one place above you).
  final Set<String> rivalUids;

  /// Opens the player page for a tapped card.
  final void Function(BoardEntry entry) onRivalTap;

  const LeaderboardPodium({
    super.key,
    required this.entries,
    required this.prizes,
    required this.rivalUids,
    required this.onRivalTap,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.length < 2) return const SizedBox.shrink();

    final sorted = [...entries]..sort((a, b) => a.rank!.compareTo(b.rank!));

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            if (i > 0) SizedBox(width: 8.w),
            Expanded(
              child: PodiumCard(
                entry: sorted[i],
                prize: sorted[i].isRanked ? prizes[sorted[i].rank] : null,
                isRival: rivalUids.contains(sorted[i].uid),
                // Any ranked player other than you opens their page. The
                // signed-in player's own card is not a target.
                onTap: (sorted[i].isRanked && !sorted[i].isCurrentUser)
                    ? () => onRivalTap(sorted[i])
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PodiumCard extends StatelessWidget {
  final BoardEntry entry;
  final double? prize;
  final bool isRival;

  /// Null for rows that are not interactive, so no ripple and no tap target.
  final VoidCallback? onTap;

  const PodiumCard({
    super.key,
    required this.entry,
    required this.prize,
    required this.isRival,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rank = entry.rank;
    final isMe = entry.isCurrentUser;
    final color =
        isMe ? LeaderboardPalette.mine : LeaderboardPalette.forRank(rank);
    final isFirst = rank == 1;
    final tappable = onTap != null;

    final card = Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 14.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isMe ? 0.08 : 0.06),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        // The winner reads as the tallest object on the podium.
        boxShadow: isFirst
            ? [
                BoxShadow(
                  color: LeaderboardPalette.gold.withValues(alpha: 0.14),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Opacity(
        opacity: entry.isRanked ? 1 : 0.5,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 2.r),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(AppRadii.full),
              ),
              child: Text(
                '#$rank',
                style: TextStyle(
                  color: AppColors.readable(color),
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            SizedBox(height: 10.h),
            Container(
              width: 48.r,
              height: 48.r,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.14),
                border: Border.all(
                  color: color.withValues(alpha: 0.45),
                  width: 1.5,
                ),
              ),
              child: Text(
                entry.initial,
                style: TextStyle(
                  color: AppColors.readable(color),
                  fontSize: 20.sp,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
            SizedBox(height: 8.h),
            Text(
              isMe ? 'You' : entry.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isMe ? AppColors.primary : AppColors.textPrimary,
                fontSize: 12.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.1,
              ),
            ),
            SizedBox(height: 3.h),
            Text(
              '${entry.weeklyPoints} pts',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (entry.isRanked && prize != null && prize! > 0) ...[
              SizedBox(height: 8.h),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(AppRadii.full),
                ),
                child: Text(
                  PrizePoolService.formatCompact(prize!),
                  style: TextStyle(
                    color: AppColors.readable(color),
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ] else if (!entry.isRanked) ...[
              SizedBox(height: 6.h),
              Text(
                'NO ENTRY',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 8.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ],
            if (isRival) ...[
              SizedBox(height: 6.h),
              const _MiniTag(label: 'RIVAL', color: LeaderboardPalette.rival),
            ],
            if (tappable) ...[
              SizedBox(height: 8.h),
              const _PlayerPageCue(compact: true),
            ],
          ],
        ),
      ),
    );

    return _TappableCard(
      onTap: onTap,
      semanticsLabel: _semantics(),
      child: card,
    );
  }

  String _semantics() {
    final parts = <String>[
      if (entry.isRanked) 'Rank ${entry.rank}' else 'No entry',
      if (entry.isCurrentUser) 'you' else entry.username,
      '${entry.weeklyPoints} points',
      if (entry.isRanked && prize != null && prize! > 0)
        PrizePoolService.formatExact(prize!),
      if (isRival) 'your rival',
      if (onTap != null) 'opens their player page',
    ];
    return parts.join(', ');
  }
}

/// A single board row.
class RankRow extends StatelessWidget {
  final BoardEntry entry;
  final double? prize;
  final bool isRival;
  final bool isMe;

  /// Marks the row that sits directly above the player, when it is visible.
  final bool isNextRank;

  /// Marks the row that sits directly below the player.
  final bool isBelowRank;

  /// Non-null for every row that is not the signed-in player. Drives both the
  /// tap target and the chevron cue so tappability is visible rather than
  /// hidden. Tapping opens the player's page.
  final VoidCallback? onTap;

  const RankRow({
    super.key,
    required this.entry,
    required this.prize,
    required this.isMe,
    required this.isRival,
    required this.isNextRank,
    required this.isBelowRank,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rank = entry.rank;
    final accent = isRival
        ? LeaderboardPalette.rival
        : isMe
            ? LeaderboardPalette.mine
            : AppColors.textPrimary;

    final bg = isRival
        ? LeaderboardPalette.rival.withValues(alpha: 0.06)
        : isMe
            ? LeaderboardPalette.mine.withValues(alpha: 0.06)
            : AppColors.surface;
    final border = isRival
        ? LeaderboardPalette.rival.withValues(alpha: 0.28)
        : isMe
            ? LeaderboardPalette.mine.withValues(alpha: 0.28)
            : AppColors.divider;

    return _TappableCard(
      onTap: onTap,
      semanticsLabel: _semantics(),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: border),
        ),
        child: Opacity(
          opacity: entry.isRanked ? 1 : 0.55,
          child: Row(
            children: [
              Container(
                width: 34.r,
                height: 34.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    // Three digits still fit the badge.
                    rank != null && rank > 0 ? '$rank' : '—',
                    style: TextStyle(
                      color: AppColors.readable(accent),
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 11.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.readable(accent),
                              fontSize: 13.sp,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.1,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (isMe) ...[
                          SizedBox(width: 5.w),
                          _MiniTag(label: 'YOU', color: AppColors.primaryText),
                        ],
                        if (isRival) ...[
                          SizedBox(width: 5.w),
                          const _MiniTag(
                            label: 'RIVAL',
                            color: LeaderboardPalette.rival,
                          ),
                        ],
                        // Tells the player which single row matters most.
                        if (isNextRank) ...[
                          SizedBox(width: 5.w),
                          _MiniTag(
                            label: 'PASS ME',
                            color: AppColors.readable(AppColors.correct),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      '${entry.weeklyPoints} pts',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (!entry.isRanked)
                Text(
                  'No entry',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else if (prize != null && prize! > 0)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
                  decoration: BoxDecoration(
                    color: AppColors.correct.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    PrizePoolService.formatCompact(prize!),
                    style: TextStyle(
                      color: AppColors.readable(AppColors.correct),
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              if (onTap != null) ...[
                SizedBox(width: 8.w),
                const _PlayerPageCue(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _semantics() {
    final parts = <String>[
      if (entry.isRanked) 'Rank ${entry.rank}' else 'No entry',
      if (isMe) 'you' else entry.username,
      '${entry.weeklyPoints} points',
      if (entry.isRanked && prize != null && prize! > 0)
        PrizePoolService.formatExact(prize!),
      if (isRival) 'rival',
      if (isNextRank) 'one place above you',
      if (onTap != null) 'opens their player page',
    ];
    return parts.join(', ');
  }
}

/// Sticky band label breaking the list into scannable rank ranges.
class RankGroupHeader extends StatelessWidget {
  final String label;

  const RankGroupHeader({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 6.h, bottom: 10.h),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: Divider(height: 1, color: AppColors.divider),
          ),
        ],
      ),
    );
  }
}

/// Divider placed inside the list to keep the player's own neighbourhood
/// visible when their rank is far from both the podium and the top of the
/// window.
class RowGap extends StatelessWidget {
  final int hiddenAbove;
  final int hiddenBelow;

  const RowGap({
    super.key,
    required this.hiddenAbove,
    required this.hiddenBelow,
  });

  @override
  Widget build(BuildContext context) {
    final label = [
      if (hiddenAbove > 0) '+$hiddenAbove above',
      if (hiddenBelow > 0) '+$hiddenBelow below',
    ].join(' · ');

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Row(
        children: [
          Expanded(
            child: Divider(height: 1, color: AppColors.divider),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 9.5.sp,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: Divider(height: 1, color: AppColors.divider),
          ),
        ],
      ),
    );
  }
}

/// Board footer: what is shown, how much is not, and when it was last read.
///
/// Carries the freshness stamp on purpose. With no pull-to-refresh and a
/// six-hour cadence, a player has no way to tell fresh rows from rows up to six
/// hours old except by being told.
class BoardFooter extends StatelessWidget {
  /// Entrant counts for the first line. Omit both when the list is not a
  /// ranked cohort (the Friends tab), so the footer shows only freshness.
  final int? shown;
  final int? totalPlayers;

  /// When the snapshot was read. Null only before the first fetch lands.
  final DateTime? fetchedAt;

  /// Overrides the second (freshness) line. The Global tab keeps the scheduled
  /// cadence wording; the Friends tab, which loads on demand, says so instead.
  final String? subtitle;

  const BoardFooter({
    super.key,
    this.shown,
    this.totalPlayers,
    required this.fetchedAt,
    this.subtitle,
  });

  /// `HH:MM` in the player's local time — when *they* last saw this data, not
  /// a UTC timestamp they would have to convert.
  static String _clockTime(DateTime at) {
    final local = at.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // totalPlayers == 0 means the true cohort size is unknown (e.g. the ghost
  // admin's view, which has no standing). Never claim such a capped board is
  // complete — fall back to "top N shown".
  static String _countLine(int shown, int totalPlayers) {
    final known = totalPlayers > 0;
    final stale = !known || totalPlayers > shown;
    final totalText = known && totalPlayers > shown ? ' of $totalPlayers' : '';
    return stale
        ? 'Showing top $shown$totalText entrants'
        : 'All $totalPlayers entrants shown';
  }

  @override
  Widget build(BuildContext context) {
    final at = fetchedAt;
    final shownCount = shown;
    final total = totalPlayers;

    return Padding(
      padding: EdgeInsets.only(top: 14.h, bottom: 6.h),
      child: Column(
        children: [
          if (shownCount != null && total != null) ...[
            Text(
              _countLine(shownCount, total),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 3.h),
          ],
          Text(
            subtitle ??
                (at == null ? 'Updating…' : 'Updated ${_clockTime(at)}'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.75),
              fontSize: 9.5.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  final String label;
  final Color color;

  const _MiniTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 1.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4.r),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.readable(color),
          fontSize: 7.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The visible "this row opens a player" cue.
///
/// A row that is tappable but looks inert is the same bug in a new costume, so
/// every tappable row and podium card carries this. It is decorative only: the
/// whole card owns the tap target, so there is no nested gesture to fight over
/// and screen readers still announce the card as one button.
class _PlayerPageCue extends StatelessWidget {
  /// Podium cards are too narrow for the label, so they carry the glyph alone.
  final bool compact;

  const _PlayerPageCue({this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        width: 30.r,
        height: 30.r,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.full),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.40),
          ),
        ),
        child: Icon(
          Icons.chevron_right_rounded,
          color: AppColors.readable(AppColors.primary),
          size: 18.r,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.chevron_right_rounded,
          color: AppColors.textMuted,
          size: 18.r,
        ),
      ],
    );
  }
}

/// Wraps a card so tappable rows get a real ripple and are announced as
/// buttons, and non-tappable rows are not falsely exposed as one.
///
/// The previous rows used a bare `GestureDetector(onTap: null)` for most of the
/// board: no ripple, no hover, and invisible to screen readers.
class _TappableCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String semanticsLabel;

  const _TappableCard({
    required this.child,
    required this.onTap,
    required this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      return Semantics(
        label: semanticsLabel,
        container: true,
        child: child,
      );
    }

    return Semantics(
      label: semanticsLabel,
      button: true,
      container: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          splashColor: AppColors.primary.withValues(alpha: 0.10),
          child: child,
        ),
      ),
    );
  }
}
