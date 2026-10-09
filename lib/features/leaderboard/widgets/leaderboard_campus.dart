import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../leaderboard_models.dart';
import 'leaderboard_position.dart';
import 'leaderboard_rows.dart';
import 'leaderboard_states.dart';

/// "My Campus" tab.
///
/// Mirrors the Global tab minus the money: the campus board pays no prize, so
/// showing a pool or per-rank naira here would be a lie. What it does carry,
/// and previously did not, is the player's own standing. A campus board whose
/// purpose is "how does my school rank" was unusable if you could not find
/// yourself in it.
class CampusLeaderboardTab extends StatefulWidget {
  /// Shared with the Global tab so both render from one read.
  final Future<LeaderboardSnapshot> snapshotFuture;

  final String? university;

  /// False until the initial university read resolves, so the tab shows a
  /// spinner instead of briefly offering the picker to someone who already has
  /// a campus.
  final bool universityLoaded;

  final ValueChanged<String> onUniversitySaved;

  /// Re-reads the shared snapshot after a failure. The only manual trigger in the
  /// app; there is no pull-to-refresh.
  final Future<void> Function() onRetry;

  const CampusLeaderboardTab({
    super.key,
    required this.snapshotFuture,
    required this.university,
    required this.universityLoaded,
    required this.onUniversitySaved,
    required this.onRetry,
  });

  @override
  State<CampusLeaderboardTab> createState() => _CampusLeaderboardTabState();
}

class _CampusLeaderboardTabState extends State<CampusLeaderboardTab>
    with AutomaticKeepAliveClientMixin {
  String? _picked;
  bool _saving = false;
  bool _editing = false;

  // Keeps this tab's State and stream subscription alive across Global and
  // Campus switches. Without it, TabBarView disposes the off-screen tab; on
  // return the StreamBuilder resubscribes to a broadcast stream that replays
  // nothing, leaving the board empty until the next Firestore push.
  @override
  bool get wantKeepAlive => true;

  Future<void> _save() async {
    final picked = _picked;
    if (picked == null || _saving) return;
    setState(() => _saving = true);
    try {
      await FirestoreService.instance.updateUniversity(picked);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
      });
      widget.onUniversitySaved(picked);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save campus - please try again.'),
          backgroundColor: AppColors.wrong,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!widget.universityLoaded) return const BoardSpinner();

    final university = widget.university;
    final noCampus = university == null || university.isEmpty;

    if (noCampus || _editing) {
      return _CampusPicker(
        picked: _editing ? university : _picked,
        saving: _saving,
        isEditing: _editing,
        onChanged: (v) => setState(() => _picked = v),
        onSave: _save,
        onCancel: _editing ? () => setState(() => _editing = false) : null,
      );
    }

    return FutureBuilder<LeaderboardSnapshot>(
      future: widget.snapshotFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return BoardErrorState(error: snap.error, onRetry: () => widget.onRetry());
        }
        if (!snap.hasData) return const BoardSpinner();

        final entries = snap.data!.campus;
        final mine = _firstWhere(entries, (e) => e.isCurrentUser);
        final campusRank = mine?.rank ?? 0;
        final above = campusRank > 1
            ? _firstWhere(entries, (e) => e.rank == campusRank - 1)
            : null;

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                  child: _CampusHeader(
                    university: university,
                    onChange: () => setState(() {
                      _editing = true;
                      _picked = university;
                    }),
                  ),
                ),
              ),

              // The campus standing this tab was missing.
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
                  child: YourPositionCard(
                    standing: WeeklyStanding(
                      rank: campusRank,
                      totalPlayers: entries.where((e) => e.isRanked).length,
                      myPoints: mine?.weeklyPoints ?? 0,
                      pointsToNextRank: above?.weeklyPoints,
                      nextRankUsername: above?.username,
                    ),
                    myWeeklyPoints: mine?.weeklyPoints ?? 0,
                    displayName: mine?.username ?? 'You',
                    isEligible: mine != null,
                  ),
                ),
              ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 20.r, 20.r, 12.r),
                  child: LeaderboardSectionHeader(
                    icon: Icons.school_rounded,
                    title: 'Campus leaderboard',
                    color: AppColors.secondary,
                    trailing: entries.isEmpty
                        ? null
                        : '${entries.length} '
                            'player${entries.length == 1 ? '' : 's'}',
                  ),
                ),
              ),

              if (entries.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: AppEmptyState(
                    icon: Icons.school_outlined,
                    title: 'No players from your campus yet',
                    message: 'Play and be the first!',
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 32.r),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => Padding(
                        padding: EdgeInsets.only(
                          bottom: i == entries.length - 1 ? 0 : 8.r,
                        ),
                        child: RankRow(
                          key: ValueKey(entries[i].uid),
                          entry: entries[i],
                          prize: null,
                          isMe: entries[i].isCurrentUser,
                          isRival: false,
                          isNextRank: campusRank > 0 &&
                              entries[i].rank == campusRank - 1,
                          isBelowRank: campusRank > 0 &&
                              entries[i].rank == campusRank + 1,
                        ),
                      ),
                      childCount: entries.length,
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 32.r),
                  child: BoardFooter(
                    shown: entries.length,
                    totalPlayers: entries.length,
                    fetchedAt: snap.data!.fetchedAt,
                  ),
                ),
              ),
            ],
        );
      },
    );
  }

  static T? _firstWhere<T>(Iterable<T> items, bool Function(T) test) {
    for (final item in items) {
      if (test(item)) return item;
    }
    return null;
  }
}

class _CampusHeader extends StatelessWidget {
  final String university;
  final VoidCallback onChange;

  const _CampusHeader({required this.university, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 44.w,
            height: 44.h,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Icon(Icons.school_rounded,
                color: AppColors.secondary, size: 22.r),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'YOUR CAMPUS',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.9,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  university,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
          // A campus set once was permanent: the picker only appeared while the
          // field was empty, so picking the wrong school locked the player into
          // a board that would never be theirs, with no way out.
          Semantics(
            button: true,
            label: 'Change campus',
            child: InkWell(
              onTap: onChange,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Change',
                      style: TextStyle(
                        color: AppColors.secondary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(width: 2.w),
                    Icon(Icons.edit_rounded,
                        color: AppColors.secondary, size: 12.r),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// University picker, used both for the first pick and for editing a bad one.
class _CampusPicker extends StatelessWidget {
  final String? picked;
  final bool saving;
  final bool isEditing;
  final ValueChanged<String?> onChanged;
  final VoidCallback onSave;
  final VoidCallback? onCancel;

  const _CampusPicker({
    required this.picked,
    required this.saving,
    required this.isEditing,
    required this.onChanged,
    required this.onSave,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 32.r, vertical: 24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.center,
              child: Container(
                width: 80.r,
                height: 80.r,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.divider),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.school_rounded,
                    color: AppColors.secondary, size: 36.r),
              ),
            ),
            SizedBox(height: 16.h),
            Text(
              isEditing ? 'Change your campus' : 'Pick your campus',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              'Choose your university to see how your school ranks against '
              'rivals across Nigeria.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.45,
              ),
            ),
            SizedBox(height: 20.h),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 14.r),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.divider),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: kNigerianUniversities.contains(picked) ? picked : null,
                  isExpanded: true,
                  dropdownColor: AppColors.surface,
                  icon: Icon(Icons.expand_more_rounded,
                      color: AppColors.textMuted, size: 20.r),
                  hint: Text(
                    'Select your university',
                    style:
                        TextStyle(color: AppColors.textMuted, fontSize: 14.sp),
                  ),
                  style:
                      TextStyle(color: AppColors.textPrimary, fontSize: 14.sp),
                  items: kNigerianUniversities
                      .map((u) => DropdownMenuItem(
                            value: u,
                            child: Text(u,
                                style: const TextStyle(
                                    color: AppColors.textPrimary)),
                          ))
                      .toList(),
                  onChanged: saving ? null : onChanged,
                ),
              ),
            ),
            SizedBox(height: 14.h),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: ElevatedButton(
                onPressed: (picked == null || saving) ? null : onSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'Save campus',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
              ),
            ),
            if (onCancel != null)
              TextButton(
                onPressed: saving ? null : onCancel,
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontFamily: 'Nunito',
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}