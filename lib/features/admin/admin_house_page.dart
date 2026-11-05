// lib/features/admin/admin_house_page.dart
//
// House top-3 control: enable/pause, gaps, WP nudges, name rotation.
// Admin-gated server-side; isAdminUid is UX-only.
//
// Presentation only — every mutation goes through AdminHouseService
// (`houseAdmin` callable, ADMIN_UIDS-gated). This file never derives
// amounts; it only renders server state and forwards explicit presets.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import 'admin_house_service.dart';
import 'admin_payout_service.dart';
import 'widgets/admin_shared.dart';

String _shortUid(String uid) =>
    uid.length <= 8 ? uid : '${uid.substring(0, 6)}…';

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

  Future<void> _confirmPauseEngine(bool enabled) async {
    if (!enabled) {
      // Enabling is harmless — apply immediately.
      await _run(
        () => AdminHouseService.instance.save({'enabled': true}),
        'Engine enabled.',
      );
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg.r),
        ),
        title:
            Text('Pause the ghost engine?', style: AppTypography.titleMedium),
        content: Text(
          'The podium bots stop defending their leads until you re-enable. '
          'Real players can pass them freely while paused.',
          style: AppTypography.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Pause',
              style: TextStyle(color: AppColors.readable(AppColors.wrong)),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(
      () => AdminHouseService.instance.save({'enabled': false}),
      'Engine paused.',
    );
  }

  Future<void> _confirmRotateAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg.r),
        ),
        title: Text('Rotate every bot name?', style: AppTypography.titleMedium),
        content: Text(
          'All podium display names are re-dealt from the pool. '
          'Scores are untouched.',
          style: AppTypography.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(
      () => AdminHouseService.instance.rotate(),
      'Names rotated.',
    );
  }

  Future<void> _openCustomNudge(HouseEntry entry) async {
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => _NudgeDialog(username: entry.username),
    );
    if (amount == null || !mounted) return;
    await _run(
      () => AdminHouseService.instance.nudge(uid: entry.uid, wp: amount),
      'Nudged +$amount WP.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<HouseSnapshot>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const AdminLoading();
        }
        if (snap.hasError || !snap.hasData) {
          final err = snap.error;
          final msg = err is AdminPayoutException
              ? err.message
              : 'Could not load house state.';
          return AdminStateView(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load',
            message: msg,
            onRetry: _reload,
          );
        }
        return _readyBody(snap.data!);
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
        title: Text('House top 3', style: AppTypography.heading3),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(child: content),
    );
  }

  Widget _readyBody(HouseSnapshot data) {
    final g = data.global;
    final enabled = (g['enabled'] as bool?) ?? true;
    final paused =
        ((g['paused'] as List?) ?? const []).map((e) => '$e').toSet();
    final topRealWp =
        data.topReal.isNotEmpty ? data.topReal.first.weeklyPoints : 0;
    final topRealName =
        data.topReal.isNotEmpty ? data.topReal.first.username : '—';

    Future<void> togglePause(HouseEntry e) => _run(() async {
          final next = Set<String>.from(paused);
          if (next.contains(e.uid)) {
            next.remove(e.uid);
          } else {
            next.add(e.uid);
          }
          await AdminHouseService.instance.save({'paused': next.toList()});
        }, 'Updated.');

    return RefreshIndicator(
      color: AppColors.readable(AppColors.primary),
      backgroundColor: AppColors.surface,
      onRefresh: () async => _reload(),
      child: ListView(
        padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 24.h),
        children: [
          _EngineCard(
            weekId: data.weekId,
            topRealName: topRealName,
            topRealWp: topRealWp,
            enabled: enabled,
            busy: _busy,
            houses: data.houses,
            onToggleEngine: () => _confirmPauseEngine(enabled),
            onRotateAll: _confirmRotateAll,
          ),
          SizedBox(height: AppSpacing.lg.h),
          AdminSectionTitle(
            title: 'Podium bots',
            trailing: '${data.houses.length} live',
          ),
          SizedBox(height: AppSpacing.sm.h),
          if (data.houses.isEmpty)
            const AppCard(
              child: Text(
                'No podium bots on this week board. They are provisioned server-side.',
              ),
            )
          else
            for (var i = 0; i < data.houses.length; i++) ...[
              _BotCard(
                badge: '#${i + 1}',
                badgeColor: _podiumColor(i),
                entry: data.houses[i],
                paused: paused.contains(data.houses[i].uid),
                busy: _busy,
                leadOverReal: data.houses[i].weeklyPoints - topRealWp,
                onTogglePause: () => togglePause(data.houses[i]),
                onNudge: (wp) => _run(
                  () => AdminHouseService.instance
                      .nudge(uid: data.houses[i].uid, wp: wp),
                  'Nudged +$wp WP.',
                ),
                onCustomNudge: () => _openCustomNudge(data.houses[i]),
                onRotate: () => _run(
                  () => AdminHouseService.instance
                      .rotate(uid: data.houses[i].uid),
                  'Name rotated.',
                ),
              ),
              SizedBox(height: AppSpacing.sm.h),
            ],
          SizedBox(height: AppSpacing.md.h),
          const AdminSectionTitle(title: 'Catch-up gaps'),
          SizedBox(height: AppSpacing.sm.h),
          _GapCard(
            global: g,
            busy: _busy,
            onSave: (patch, ok) => _run(
              () => AdminHouseService.instance.save(patch),
              ok,
            ),
          ),
          SizedBox(height: AppSpacing.lg.h),
          const AdminSectionTitle(title: 'Social humanizer'),
          SizedBox(height: AppSpacing.sm.h),
          _SocialCard(
            global: g,
            social: data.social,
            busy: _busy,
            onSave: (patch, ok) => _run(
              () => AdminHouseService.instance.save(patch),
              ok,
            ),
          ),
        ],
      ),
    );
  }
}

Color _podiumColor(int index) {
  switch (index) {
    case 0:
      return AppColors.gold;
    case 1:
      return AppColors.silver;
    case 2:
      return AppColors.bronze;
    default:
      return AppColors.secondary;
  }
}

// ─── Engine status ───────────────────────────────────────────────────────────

class _EngineCard extends StatelessWidget {
  final String weekId;
  final String topRealName;
  final int topRealWp;
  final bool enabled;
  final bool busy;
  final List<HouseEntry> houses;
  final VoidCallback onToggleEngine;
  final VoidCallback onRotateAll;

  const _EngineCard({
    required this.weekId,
    required this.topRealName,
    required this.topRealWp,
    required this.enabled,
    required this.busy,
    required this.houses,
    required this.onToggleEngine,
    required this.onRotateAll,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = enabled ? AppColors.correct : AppColors.wrong;
    return AppCard(
      accentColor: statusColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                enabled ? Icons.shield_rounded : Icons.shield_outlined,
                color: AppColors.readable(statusColor),
                size: 18.r,
              ),
              SizedBox(width: AppSpacing.sm.w),
              Expanded(
                child: Text('Ghost engine', style: AppTypography.titleMedium),
              ),
              AdminChip(
                label: enabled ? 'ON' : 'PAUSED',
                color: statusColor,
              ),
            ],
          ),
          SizedBox(height: AppSpacing.xs.h),
          Text(
            'Week of $weekId · Top real: $topRealName · $topRealWp WP',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.md.h),
          Row(
            children: [
              for (var i = 0; i < 3; i++)
                Expanded(
                  child: Padding(
                    padding:
                        EdgeInsets.only(right: i < 2 ? AppSpacing.sm.w : 0),
                    child: _WpTile(
                      label: 'H${i + 1}',
                      value:
                          i < houses.length ? '${houses[i].weeklyPoints}' : '—',
                      color: _podiumColor(i),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: AppSpacing.md.h),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: busy
                      ? 'Saving…'
                      : (enabled ? 'Pause engine' : 'Enable engine'),
                  variant: AppButtonVariant.outline,
                  size: AppButtonSize.small,
                  loading: busy,
                  color: enabled ? AppColors.wrong : null,
                  onPressed: busy ? null : onToggleEngine,
                ),
              ),
              SizedBox(width: AppSpacing.sm.w),
              Expanded(
                child: AppButton(
                  label: 'Rotate names',
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  icon: Icon(Icons.autorenew_rounded, size: 15.r),
                  onPressed: busy ? null : onRotateAll,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WpTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _WpTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.md.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTypography.labelSmall.copyWith(
              color: AppColors.readable(color),
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 2.h),
          Text(
            '$value WP',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.titleMedium.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bot card ────────────────────────────────────────────────────────────────

class _BotCard extends StatelessWidget {
  final String badge;
  final Color badgeColor;
  final HouseEntry entry;
  final bool paused;
  final bool busy;
  final int leadOverReal;
  final VoidCallback onTogglePause;
  final ValueChanged<int> onNudge;
  final VoidCallback onCustomNudge;
  final VoidCallback onRotate;

  const _BotCard({
    required this.badge,
    required this.badgeColor,
    required this.entry,
    required this.paused,
    required this.busy,
    required this.leadOverReal,
    required this.onTogglePause,
    required this.onNudge,
    required this.onCustomNudge,
    required this.onRotate,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = paused ? AppColors.wrong : badgeColor;
    return AppCard(
      padding: EdgeInsets.all(AppSpacing.md.r),
      accentColor: paused ? AppColors.wrong : badgeColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38.r,
                height: 38.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.md.r),
                  border: Border.all(
                    color: badgeColor.withValues(alpha: 0.40),
                  ),
                ),
                child: Text(
                  badge,
                  style: AppTypography.titleMedium.copyWith(
                    color: AppColors.readable(badgeColor),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SizedBox(width: AppSpacing.sm.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.titleMedium.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'uid ${_shortUid(entry.uid)}',
                      style: AppTypography.bodySmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${entry.weeklyPoints} WP',
                    style: AppTypography.titleMedium.copyWith(
                      color: AppColors.readable(AppColors.correct),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    leadOverReal >= 0
                        ? '+$leadOverReal over real'
                        : '$leadOverReal behind real',
                    style: AppTypography.bodySmall.copyWith(
                      color: leadOverReal >= 0
                          ? AppColors.textMuted
                          : AppColors.readable(AppColors.wrong),
                    ),
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm.h),
          Wrap(
            spacing: AppSpacing.sm.r,
            runSpacing: AppSpacing.sm.r,
            children: [
              if (paused) AdminChip(label: 'PAUSED', color: AppColors.wrong),
              AdminChip(
                label: paused ? 'HELD OUT' : 'DEFENDING',
                color: paused ? AppColors.textMuted : AppColors.correct,
              ),
            ],
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
                label: 'Custom',
                variant: AppButtonVariant.text,
                size: AppButtonSize.small,
                onPressed: busy ? null : onCustomNudge,
              ),
              AppButton(
                label: 'Rotate',
                variant: AppButtonVariant.text,
                size: AppButtonSize.small,
                icon: Icon(Icons.autorenew_rounded, size: 14.r),
                onPressed: busy ? null : onRotate,
              ),
            ],
          ),
          // Keep the accent readable without exposing internals.
          if (statusColor == AppColors.wrong && paused)
            Padding(
              padding: EdgeInsets.only(top: AppSpacing.xs.h),
              child: Text(
                'Paused bots sit out of the nightly tick until resumed.',
                style: AppTypography.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Catch-up gaps ───────────────────────────────────────────────────────────

class _GapCard extends StatelessWidget {
  final Map<String, dynamic> global;
  final bool busy;
  final void Function(Map<String, dynamic> patch, String ok) onSave;

  const _GapCard({
    required this.global,
    required this.busy,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How far bots stay ahead', style: AppTypography.titleMedium),
          SizedBox(height: AppSpacing.xs.h),
          Text(
            'H3 leads real #4 inside 30–200 WP so the board stays catchable. '
            'Roles rotate every tick so H1/H2/H3 keep overtaking each other.',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.md.h),
          _GapRow(
            title: 'H1 gap',
            current: (global['gap1'] as num?)?.toInt() ?? 110,
            hint: 'Lead H1 holds over H2.',
            options: const [
              (label: 'Tight 95', value: 95),
              (label: 'Standard 110', value: 110),
              (label: 'Wide 120', value: 120),
            ],
            busy: busy,
            onSelect: (v) => onSave({'gap1': v}, 'gap1 set to $v.'),
          ),
          Divider(height: AppSpacing.lg.h, color: AppColors.divider),
          _GapRow(
            title: 'H2 gap',
            current: (global['gap2'] as num?)?.toInt() ?? 85,
            hint: 'Lead H2 holds over H3.',
            options: const [
              (label: 'Tight 75', value: 75),
              (label: 'Standard 85', value: 85),
              (label: 'Wide 100', value: 100),
            ],
            busy: busy,
            onSelect: (v) => onSave({'gap2': v}, 'gap2 set to $v.'),
          ),
          Divider(height: AppSpacing.lg.h, color: AppColors.divider),
          _GapRow(
            title: 'H3 gap',
            current: (global['gap3'] as num?)?.toInt() ?? 95,
            hint: 'Lead H3 holds over real #4. The catchability lever.',
            options: const [
              (label: 'Tight 70', value: 70),
              (label: 'Standard 95', value: 95),
              (label: 'Wide 110', value: 110),
            ],
            busy: busy,
            onSelect: (v) => onSave({'gap3': v}, 'gap3 set to $v.'),
          ),
          Divider(height: AppSpacing.lg.h, color: AppColors.divider),
          _GapRow(
            title: 'Sunday reserve',
            current: (global['reserve'] as num?)?.toInt() ?? 1200,
            hint: 'Extra WP H3 can spend on Sunday to stay ahead.',
            options: const [
              (label: 'Low 620', value: 620),
              (label: 'Standard 1200', value: 1200),
              (label: 'High 2000', value: 2000),
            ],
            busy: busy,
            onSelect: (v) =>
                onSave({'reserve': v}, 'Sunday reserve set to $v.'),
          ),
        ],
      ),
    );
  }
}

class _GapRow extends StatelessWidget {
  final String title;
  final int current;
  final String hint;
  final List<({String label, int value})> options;
  final bool busy;
  final ValueChanged<int> onSelect;

  const _GapRow({
    required this.title,
    required this.current,
    required this.hint,
    required this.options,
    required this.busy,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final known = options.any((o) => o.value == current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: AppTypography.labelLarge),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 9.w, vertical: 4.h),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadii.full.r),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                '$current WP',
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.readable(AppColors.primary),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 2.h),
        Text(hint, style: AppTypography.bodySmall),
        SizedBox(height: AppSpacing.sm.h),
        Wrap(
          spacing: AppSpacing.sm.r,
          runSpacing: AppSpacing.sm.r,
          children: [
            for (final o in options)
              _OptionPill(
                label: o.label,
                active: o.value == current,
                onTap: busy ? null : () => onSelect(o.value),
              ),
            if (!known)
              AdminChip(label: 'Custom $current', color: AppColors.amber),
          ],
        ),
      ],
    );
  }
}

class _OptionPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _OptionPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.14)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.full.r),
          border: Border.all(
            color: active
                ? AppColors.primary.withValues(alpha: 0.55)
                : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.labelMedium.copyWith(
            color: active
                ? AppColors.readable(AppColors.primary)
                : AppColors.textSecondary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// ─── Social humanizer ────────────────────────────────────────────────────────

class _SocialCard extends StatelessWidget {
  final Map<String, dynamic> global;
  final List<Map<String, dynamic>> social;
  final bool busy;
  final void Function(Map<String, dynamic> patch, String ok) onSave;

  const _SocialCard({
    required this.global,
    required this.social,
    required this.busy,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final socialOn = (global['socialEnabled'] ?? true) == true;
    final outgoingOn = (global['outgoingEnabled'] ?? true) == true;
    final unlocksOn = (global['unlockAnimeEnabled'] ?? true) == true;
    final statusColor = socialOn ? AppColors.correct : AppColors.wrong;

    return AppCard(
      accentColor: statusColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Human-like social',
                  style: AppTypography.titleMedium,
                ),
              ),
              AdminChip(
                label: socialOn ? 'ON' : 'OFF',
                color: statusColor,
              ),
            ],
          ),
          SizedBox(height: AppSpacing.xs.h),
          Text(
            'Bots accept friends, spars and duels like premium humans — about 60% duel wins with streaks, varied stakes and a 6-minute play floor.',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.sm.h),
          AppButton(
            label: busy
                ? 'Saving…'
                : (socialOn ? 'Disable social' : 'Enable social'),
            variant: AppButtonVariant.outline,
            size: AppButtonSize.small,
            loading: busy,
            onPressed: busy
                ? null
                : () => onSave(
                      {'socialEnabled': !socialOn},
                      socialOn ? 'Social disabled.' : 'Social enabled.',
                    ),
          ),
          SizedBox(height: AppSpacing.md.h),
          Wrap(
            spacing: AppSpacing.sm.r,
            runSpacing: AppSpacing.sm.r,
            children: [
              _RateTile(
                label: 'Duel accept',
                value: '${global['duelAcceptRate'] ?? 65}%',
              ),
              _RateTile(
                label: 'Duel win',
                value: '${global['winRate'] ?? 60}%',
              ),
              _RateTile(
                label: 'Spar accept',
                value: '${global['sparAcceptRate'] ?? 75}%',
              ),
              _RateTile(
                label: 'High-stake',
                value: '${global['highStakeAcceptRate'] ?? 35}%',
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm.h),
          Wrap(
            spacing: AppSpacing.sm.r,
            runSpacing: AppSpacing.sm.r,
            children: [
              _TogglePill(
                label: 'Outgoing ${outgoingOn ? 'on' : 'off'}',
                active: outgoingOn,
                onTap: busy
                    ? null
                    : () => onSave(
                          {'outgoingEnabled': !outgoingOn},
                          'Outgoing updated.',
                        ),
              ),
              _TogglePill(
                label: 'Unlocks ${unlocksOn ? 'on' : 'off'}',
                active: unlocksOn,
                onTap: busy
                    ? null
                    : () => onSave(
                          {'unlockAnimeEnabled': !unlocksOn},
                          'Unlocks updated.',
                        ),
              ),
            ],
          ),
          if (social.isNotEmpty) ...[
            SizedBox(height: AppSpacing.md.h),
            Text('Per-bot activity', style: AppTypography.labelLarge),
            SizedBox(height: AppSpacing.sm.h),
            for (final s in social) ...[
              _SocialBotTile(data: s),
              SizedBox(height: AppSpacing.sm.h),
            ],
          ] else ...[
            SizedBox(height: AppSpacing.sm.h),
            Text(
              'No social rows yet — activity appears after the next engine tick.',
              style: AppTypography.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _RateTile extends StatelessWidget {
  final String label;
  final String value;

  const _RateTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 7.h),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.md.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: RichText(
        text: TextSpan(
          style: AppTypography.bodySmall,
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: AppTypography.labelLarge.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _TogglePill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.correct : AppColors.textMuted;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.full.r),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: AppTypography.labelMedium.copyWith(
            color: AppColors.readable(color),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _SocialBotTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const _SocialBotTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final uid = (data['uid'] as String?) ?? '';
    final friends = (data['friendCount'] as num?)?.toInt() ?? 0;
    final incoming = (data['incomingFriends'] as num?)?.toInt() ?? 0;
    final outgoing = (data['outgoingFriends'] as num?)?.toInt() ?? 0;
    final duels = (data['waitingDuels'] as num?)?.toInt() ?? 0;
    final queued = (data['pendingPlays'] as num?)?.toInt() ?? 0;
    final today = (data['socialActionsToday'] as num?)?.toInt() ?? 0;
    return Container(
      padding: EdgeInsets.all(AppSpacing.sm.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.md.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 34.r,
            height: 34.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.sm.r),
            ),
            child: Text(
              uid.isEmpty ? '?' : uid.substring(0, 1).toUpperCase(),
              style: AppTypography.titleMedium.copyWith(
                color: AppColors.readable(AppColors.primary),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(width: AppSpacing.sm.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bot ${_shortUid(uid)} · $friends friends',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.labelLarge.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  '$incoming in · $outgoing out · $duels duels · $queued queued · $today today',
                  style: AppTypography.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Custom nudge ────────────────────────────────────────────────────────────

class _NudgeDialog extends StatefulWidget {
  final String username;

  const _NudgeDialog({required this.username});

  @override
  State<_NudgeDialog> createState() => _NudgeDialogState();
}

class _NudgeDialogState extends State<_NudgeDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_ctrl.text.trim());
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter WP greater than zero.');
      return;
    }
    if (value > 1000) {
      setState(() => _error = 'Keep it under 1000 WP per nudge.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg.r),
      ),
      title: Text(
        'Nudge ${widget.username}',
        style: AppTypography.titleMedium,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Adds weekly points instantly. Small nudges keep the race believable.',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.sm.h),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            autofocus: true,
            onSubmitted: (_) => _submit(),
            style: AppTypography.labelLarge,
            decoration: InputDecoration(
              hintText: 'e.g. 25',
              errorText: _error,
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12.r,
                vertical: 12.r,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md.r),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md.r),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Nudge'),
        ),
      ],
    );
  }
}
