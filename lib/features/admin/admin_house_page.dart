// lib/features/admin/admin_house_page.dart
//
// House top-3 control: enable/pause, gaps, WP nudges, name rotation.
// Admin-gated server-side; isAdminUid is UX-only.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import 'admin_house_service.dart';
import 'admin_payout_service.dart';

class AdminHousePage extends StatefulWidget {
  /// When true, renders only the tab body (no Scaffold/AppBar) so the admin
  /// console can host it under its own navigation.
  final bool embedded;
  const AdminHousePage({super.key, this.embedded = false});

  @override
  State<AdminHousePage> createState() => _AdminHousePageState();
}

class _AdminHousePageState extends State<AdminHousePage> {
  late Future<HouseSnapshot> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = AdminHouseService.instance.fetch();
  }

  void _reload() {
    setState(() => _future = AdminHouseService.instance.fetch());
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _run(Future<void> Function() fn, String ok) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
      if (!mounted) return;
      _snack(ok);
      _reload();
    } on AdminPayoutException catch (e) {
      if (mounted) _snack('${e.message} [${e.code}]');
    } catch (e) {
      if (mounted) _snack('Request failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<HouseSnapshot>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        if (snap.hasError || !snap.hasData) {
          final err = snap.error;
          final msg = err is AdminPayoutException
              ? err.message
              : 'Could not load house state.';
          return Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg.r),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(msg,
                      textAlign: TextAlign.center,
                      style: AppTypography.bodyMedium
                          .copyWith(color: AppColors.textSecondary)),
                  SizedBox(height: AppSpacing.md.h),
                  AppButton(
                    label: 'Retry',
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.small,
                    onPressed: _reload,
                  ),
                ],
              ),
            ),
          );
        }
        final data = snap.data!;
        final g = data.global;
        final enabled = (g['enabled'] as bool?) ?? true;
        final paused =
            ((g['paused'] as List?) ?? const []).map((e) => '$e').toSet();
        final r4 =
            data.topReal.isNotEmpty ? data.topReal.first.weeklyPoints : 0;
        return RefreshIndicator(
          color: AppColors.primary,
          backgroundColor: AppColors.surface,
          onRefresh: () async => _reload(),
          child: ListView(
            padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Week of ${data.weekId}',
                        style: AppTypography.titleMedium),
                    SizedBox(height: AppSpacing.xs.h),
                    Text(
                      'Top real: ${data.topReal.isNotEmpty ? '${data.topReal.first.username} · $r4 WP' : '—'}',
                      style: AppTypography.bodySmall
                          .copyWith(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: AppSpacing.sm.h),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            enabled ? 'Engine ON' : 'Engine PAUSED',
                            style: AppTypography.labelLarge.copyWith(
                              color:
                                  enabled ? AppColors.correct : AppColors.wrong,
                            ),
                          ),
                        ),
                        AppButton(
                          label: _busy
                              ? 'Saving…'
                              : (enabled ? 'Pause all' : 'Enable all'),
                          variant: AppButtonVariant.outline,
                          size: AppButtonSize.small,
                          loading: _busy,
                          onPressed: _busy
                              ? null
                              : () => _run(
                                    () => AdminHouseService.instance
                                        .save({'enabled': !enabled}),
                                    enabled ? 'Paused.' : 'Enabled.',
                                  ),
                        ),
                      ],
                    ),
                    SizedBox(height: AppSpacing.sm.h),
                    Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            label: 'Rotate all names',
                            variant: AppButtonVariant.secondary,
                            size: AppButtonSize.small,
                            onPressed: _busy
                                ? null
                                : () => _run(
                                      () => AdminHouseService.instance.rotate(),
                                      'Names rotated.',
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: AppSpacing.md.h),
              for (var i = 0; i < data.houses.length; i++) ...[
                _HouseCard(
                  rank: i + 1,
                  entry: data.houses[i],
                  paused: paused.contains(data.houses[i].uid),
                  busy: _busy,
                  onTogglePause: () => _run(() async {
                    final next = Set<String>.from(paused);
                    if (next.contains(data.houses[i].uid)) {
                      next.remove(data.houses[i].uid);
                    } else {
                      next.add(data.houses[i].uid);
                    }
                    await AdminHouseService.instance
                        .save({'paused': next.toList()});
                  }, 'Updated.'),
                  onNudge: (wp) => _run(
                    () => AdminHouseService.instance
                        .nudge(uid: data.houses[i].uid, wp: wp),
                    'Nudged +$wp WP.',
                  ),
                  onRotate: () => _run(
                    () => AdminHouseService.instance
                        .rotate(uid: data.houses[i].uid),
                    'Name rotated.',
                  ),
                ),
                SizedBox(height: AppSpacing.sm.h),
              ],
              if (data.chasers.isNotEmpty) ...[
                Text('Chasers (mid-board)', style: AppTypography.titleMedium),
                SizedBox(height: AppSpacing.xs.h),
                for (var i = 0; i < data.chasers.length; i++) ...[
                  _HouseCard(
                    rank: i + 1,
                    entry: data.chasers[i],
                    paused: paused.contains(data.chasers[i].uid),
                    busy: _busy,
                    onTogglePause: () => _run(() async {
                      final next = Set<String>.from(paused);
                      if (next.contains(data.chasers[i].uid)) {
                        next.remove(data.chasers[i].uid);
                      } else {
                        next.add(data.chasers[i].uid);
                      }
                      await AdminHouseService.instance
                          .save({'paused': next.toList()});
                    }, 'Updated.'),
                    onNudge: (wp) => _run(
                      () => AdminHouseService.instance
                          .nudge(uid: data.chasers[i].uid, wp: wp),
                      'Nudged +$wp WP.',
                    ),
                    onRotate: () => _run(
                      () => AdminHouseService.instance
                          .rotate(uid: data.chasers[i].uid),
                      'Name rotated.',
                    ),
                  ),
                  SizedBox(height: AppSpacing.sm.h),
                ],
              ],
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Catch-up gap', style: AppTypography.titleMedium),
                    SizedBox(height: AppSpacing.xs.h),
                    Text(
                      'H3 leads real #4 inside gapMin-gapMax (30-200 catchable, upset day can flip). Roles shuffle daily so H1/H2/H3 swap; chasers stay 60+ below H3.',
                      style: AppTypography.bodySmall
                          .copyWith(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: AppSpacing.sm.h),
                    Wrap(
                      spacing: AppSpacing.sm.r,
                      runSpacing: AppSpacing.sm.r,
                      children: [
                        _GapChip(
                            label: 'gap1 ${g['gap1'] ?? 95}',
                            onTap: _busy
                                ? null
                                : () => _run(
                                    () => AdminHouseService.instance
                                        .save({'gap1': 95}),
                                    'gap1 set to 95.'),
                            onLong: _busy
                                ? null
                                : () => _run(
                                    () => AdminHouseService.instance
                                        .save({'gap1': 120}),
                                    'gap1 set to 120.')),
                        _GapChip(
                            label: 'gap2 ${g['gap2'] ?? 75}',
                            onTap: _busy
                                ? null
                                : () => _run(
                                    () => AdminHouseService.instance
                                        .save({'gap2': 75}),
                                    'gap2 set to 75.')),
                        _GapChip(
                            label: 'gap3 ${g['gap3'] ?? 70}',
                            onTap: _busy
                                ? null
                                : () => _run(
                                    () => AdminHouseService.instance
                                        .save({'gap3': 70}),
                                    'gap3 set to 70.')),
                        _GapChip(
                            label: 'reserve ${g['reserve'] ?? 620}',
                            onTap: _busy
                                ? null
                                : () => _run(
                                    () => AdminHouseService.instance
                                        .save({'reserve': 620}),
                                    'Sunday reserve set to 620.')),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: AppSpacing.sm.h),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Social humanizer', style: AppTypography.titleMedium),
                    SizedBox(height: AppSpacing.xs.h),
                    Text(
                      'Bots accept/decline friends, spars and duels like premium humans. ~60% duel wins with streaks, varied stakes, 6-min play floor, 5k unlocks.',
                      style: AppTypography.bodySmall
                          .copyWith(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: AppSpacing.sm.h),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            (g['socialEnabled'] ?? true) == true
                                ? 'Social ON'
                                : 'Social OFF',
                            style: AppTypography.labelLarge.copyWith(
                              color: (g['socialEnabled'] ?? true) == true
                                  ? AppColors.correct
                                  : AppColors.wrong,
                            ),
                          ),
                        ),
                        AppButton(
                          label: (g['socialEnabled'] ?? true) == true
                              ? 'Disable'
                              : 'Enable',
                          variant: AppButtonVariant.outline,
                          size: AppButtonSize.small,
                          loading: _busy,
                          onPressed: _busy
                              ? null
                              : () => _run(
                                    () => AdminHouseService.instance.save({
                                      'socialEnabled':
                                          !((g['socialEnabled'] ?? true) ==
                                              true),
                                    }),
                                    'Social updated.',
                                  ),
                        ),
                      ],
                    ),
                    SizedBox(height: AppSpacing.sm.h),
                    Wrap(
                      spacing: AppSpacing.sm.r,
                      runSpacing: AppSpacing.sm.r,
                      children: [
                        _GapChip(
                            label:
                                'duel ${g['duelAcceptRate'] ?? 70}% / win ${g['winRate'] ?? 80}%',
                            onTap: null),
                        _GapChip(
                            label: 'spar ${g['sparAcceptRate'] ?? 80}%',
                            onTap: null),
                        _GapChip(
                            label:
                                'high-stake ${g['highStakeAcceptRate'] ?? 40}%',
                            onTap: null),
                        _GapChip(
                            label:
                                'outgoing ${(g['outgoingEnabled'] ?? true) == true ? 'on' : 'off'}',
                            onTap: _busy
                                ? null
                                : () => _run(
                                      () => AdminHouseService.instance.save({
                                        'outgoingEnabled':
                                            !((g['outgoingEnabled'] ?? true) ==
                                                true),
                                      }),
                                      'Outgoing updated.',
                                    )),
                        _GapChip(
                            label:
                                'unlocks ${(g['unlockAnimeEnabled'] ?? true) == true ? 'on' : 'off'}',
                            onTap: _busy
                                ? null
                                : () => _run(
                                      () => AdminHouseService.instance.save({
                                        'unlockAnimeEnabled':
                                            !((g['unlockAnimeEnabled'] ??
                                                    true) ==
                                                true),
                                      }),
                                      'Unlocks updated.',
                                    )),
                      ],
                    ),
                    if (data.social.isNotEmpty) ...[
                      SizedBox(height: AppSpacing.sm.h),
                      for (final s in data.social)
                        Text(
                          '${(s['uid'] as String? ?? '').length > 6 ? (s['uid'] as String).substring(0, 6) : s['uid']}: ${s['friendCount'] ?? 0} friends · ${s['incomingFriends'] ?? 0} in · ${s['outgoingFriends'] ?? 0} out · ${s['waitingDuels'] ?? 0} duels · ${s['pendingPlays'] ?? 0} queued · ${s['socialActionsToday'] ?? 0} today',
                          style: AppTypography.bodySmall
                              .copyWith(color: AppColors.textMuted),
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
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: const AppBackButton(),
        title: Text(
          'House top 3',
          style: AppTypography.heading3,
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: content,
    );
  }
}

class _HouseCard extends StatelessWidget {
  final int rank;
  final HouseEntry entry;
  final bool paused;
  final bool busy;
  final VoidCallback onTogglePause;
  final ValueChanged<int> onNudge;
  final VoidCallback onRotate;

  const _HouseCard({
    required this.rank,
    required this.entry,
    required this.paused,
    required this.busy,
    required this.onTogglePause,
    required this.onNudge,
    required this.onRotate,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('#$rank ${entry.username}',
                  style: AppTypography.titleMedium),
              const Spacer(),
              Text('${entry.weeklyPoints} WP',
                  style: AppTypography.labelLarge
                      .copyWith(color: AppColors.correct)),
            ],
          ),
          SizedBox(height: AppSpacing.xs.h),
          Text(
            '${entry.uid.length > 8 ? '${entry.uid.substring(0, 6)}…' : entry.uid}${paused ? ' · paused' : ''}',
            style: AppTypography.bodySmall.copyWith(color: AppColors.textMuted),
          ),
          SizedBox(height: AppSpacing.sm.h),
          Wrap(
            spacing: AppSpacing.sm.r,
            runSpacing: AppSpacing.sm.r,
            children: [
              AppButton(
                label: paused ? 'Resume' : 'Pause',
                variant: AppButtonVariant.outline,
                size: AppButtonSize.small,
                onPressed: busy ? null : onTogglePause,
              ),
              AppButton(
                label: '+50',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                onPressed: busy ? null : () => onNudge(50),
              ),
              AppButton(
                label: '+100',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                onPressed: busy ? null : () => onNudge(100),
              ),
              AppButton(
                label: 'Rotate name',
                variant: AppButtonVariant.text,
                size: AppButtonSize.small,
                onPressed: busy ? null : onRotate,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GapChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLong;
  const _GapChip({required this.label, this.onTap, this.onLong});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLong,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 7.r),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadii.full.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(label, style: AppTypography.labelMedium),
      ),
    );
  }
}
