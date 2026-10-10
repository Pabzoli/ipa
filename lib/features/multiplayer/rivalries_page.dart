// lib/features/multiplayer/rivalries_page.dart
//
// Dedicated Rivalries page (extracted from the Battle hub).
//
// Holds what the Hub used to cram into one card:
//   • rival list (recentRivals, limit 30 — the Hub keeps its own limit-8
//     preview capped at 5 plus a "View rivalries" link here),
//   • discovery (campus suggestions + code join/create),
//   • entry points into RivalryPage (per-rival detail: series state, history,
//     Spar/Duel buttons — that page is unchanged).
//
// No listeners: one-shot futures + pull-to-refresh. No "rank" copy anywhere:
// series standing is not a rank.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/rival_economy.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_page_route.dart';
import 'anime_select_page.dart';
import 'join_challenge_page.dart';
import 'rivalry_page.dart';

class RivalriesPage extends StatefulWidget {
  const RivalriesPage({super.key});

  @override
  State<RivalriesPage> createState() => _RivalriesPageState();
}

class _RivalriesPageState extends State<RivalriesPage> {
  Future<List<RivalSummary>>? _rivalsFuture;

  @override
  void initState() {
    super.initState();
    _rivalsFuture = FirestoreService.instance.recentRivals(limit: 30);
  }

  Future<void> _reload() async {
    final f = FirestoreService.instance.recentRivals(limit: 30);
    setState(() => _rivalsFuture = f);
    try {
      await f;
    } catch (_) {
      // Rendered by the FutureBuilder error state below.
    }
  }

  void _openRivalry(String uid, String username) {
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => RivalryPage(rivalUid: uid, rivalUsername: username),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Rivalries',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: AppColors.surface,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
          children: [
            _SectionCard(
              title: 'Your rivalries',
              subtitle:
                  'First to $kSeriesWinsRequired staked duels takes the series. '
                  'Draws replay and never count. Sparring never counts.',
              child: FutureBuilder<List<RivalSummary>>(
                future: _rivalsFuture,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary),
                      ),
                    );
                  }
                  if (snap.hasError) {
                    return _Note(
                      text:
                          'Could not load rivalries: ${snap.error}. Pull to retry.',
                    );
                  }
                  final rivals = snap.data ?? [];
                  if (rivals.isEmpty) {
                    return const _Note(
                      text:
                          'No rivalries yet. Duel someone by code or from your '
                          'campus below — they will show up here.',
                    );
                  }
                  return Column(
                    children: [
                      for (final r in rivals)
                        _RivalryRow(
                          name: r.username,
                          detail:
                              '${r.wins}W · ${r.draws}D · ${r.losses}L',
                          badge: r.lastWasLoss ? 'REMATCH' : null,
                          actionLabel:
                              r.lastWasLoss ? 'Revenge' : 'Open',
                          onTap: () => _openRivalry(r.uid, r.username),
                        ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: 14.h),
            _SectionCard(
              title: 'Find a rival',
              subtitle: 'Campus suggestions · code join · code create.',
              child: Column(
                children: [
                  _CampusSuggestions(
                    onOpen: _openRivalry,
                  ),
                  SizedBox(height: 10.h),
                  Row(
                    children: [
                      Expanded(
                        child: _SmallButton(
                          label: 'Join by code',
                          onTap: () => Navigator.of(context).push(
                            AppPageRoute(
                              builder: (_) => const JoinChallengePage(),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: _SmallButton(
                          label: 'Create code duel',
                          onTap: () => Navigator.of(context).push(
                            AppPageRoute(
                              builder: (_) => const AnimeSelectPage(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: AppColors.divider.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w800)),
          SizedBox(height: 4.h),
          Text(subtitle,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.sp)),
          SizedBox(height: 10.h),
          child,
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 10.h, horizontal: 4.r),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 12.sp,
          fontWeight: FontWeight.w600,
          height: 1.5,
        ),
      ),
    );
  }
}

class _RivalryRow extends StatelessWidget {
  final String name;
  final String detail;
  final String? badge;
  final String actionLabel;
  final VoidCallback onTap;

  const _RivalryRow({
    required this.name,
    required this.detail,
    this.badge,
    required this.actionLabel,
    required this.onTap,
  });

  static const _rival = Color(0xFFFF6B00);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 8.h),
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
              color: _rival.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: TextStyle(
                color: _rival,
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (badge != null) ...[
                      SizedBox(width: 6.w),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.r, vertical: 2.r),
                        decoration: BoxDecoration(
                          color: _rival.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(5.r),
                        ),
                        child: Text(
                          badge!,
                          style: TextStyle(
                            color: _rival,
                            fontSize: 8.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: 2.h),
                Text(
                  detail,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8.w),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
              decoration: BoxDecoration(
                color: _rival.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(
                  color: _rival.withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                actionLabel,
                style: TextStyle(
                  color: _rival,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SmallButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12.r),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(label,
            style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.sp,
                fontWeight: FontWeight.w800)),
      ),
    );
  }
}

/// Campus suggestions, moved from the deleted rival discovery sheet.
/// Same-university, same-week players, ordered by WP. Tapping a row opens
/// the per-rival detail page (Spar/Duel live there).
class _CampusSuggestions extends StatelessWidget {
  final void Function(String uid, String username) onOpen;

  const _CampusSuggestions({required this.onOpen});

  Future<List<RivalCandidate>?> _load() async {
    final me = FirestoreService.instance.currentUid;
    if (me == null) return [];
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(me)
        .get();
    final data = doc.data() ?? {};
    final uni = (data['university'] as String?) ?? '';
    final week = (data['leaderboardEntryWeekId'] as String?) ?? '';
    if (uni.isEmpty || week.isEmpty) return null;
    return FirestoreService.instance.campusRivals(
      university: uni,
      weekId: week,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<RivalCandidate>?>(
      future: _load(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }
        final rows = snap.data;
        if (rows == null) {
          return const _Note(
            text:
                'Set your university and join the weekly board to see campus rivals.',
          );
        }
        // Hide people already in the rival list is intentionally skipped:
        // this is a cheap suggestion row (max 20, one query, no extra
        // per-row reads), and the detail page is idempotent.
        final shown = rows.take(5).toList();
        if (shown.isEmpty) {
          return const _Note(
            text: 'No campus rivals on the board this week — yet.',
          );
        }
        return Column(
          children: [
            for (final r in shown)
              _RivalryRow(
                name: r.username,
                detail: '${r.weeklyPoints} WP this week',
                actionLabel: 'Open',
                onTap: () => onOpen(r.uid, r.username),
              ),
          ],
        );
      },
    );
  }
}
