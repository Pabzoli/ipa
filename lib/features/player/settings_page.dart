// lib/features/player/settings_page.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/solo_economy.dart';
import '../../core/providers/solo_difficulty_provider.dart';
import '../../core/providers/theme_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_page_route.dart';
import '../../feature/support/presentation/support_screen/ui/support_screen.dart';
import '../auth/auth_service.dart';
import 'purchases_page.dart';

/// Central settings hub reached from Profile → Account → Settings.
///
/// Holds the homepage difficulty picker (the only place it can be changed),
/// the campus picker, support/legal links and account deletion. Everything
/// visible here is either persisted instantly (difficulty) or saved explicitly
/// (campus), so there is no global "save" button.
class SettingsPage extends StatelessWidget {
  final VoidCallback onDeleteAccount;

  const SettingsPage({super.key, required this.onDeleteAccount});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _SettingsHeader(),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 36.r),
                children: [
                  if (kThemeControlEnabled) ...[
                    const _SectionLabel('Appearance'),
                    SizedBox(height: 8.h),
                    const _AppearanceSettingsCard(),
                    SizedBox(height: 6.h),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4.r),
                      child: Text(
                        'System follows your device appearance.',
                        style: AppTypography.bodySmall,
                      ),
                    ),
                    SizedBox(height: 22.h),
                  ],
                  const _SectionLabel('Difficulty'),
                  SizedBox(height: 8.h),
                  const _DifficultySettingsCard(),
                  SizedBox(height: 22.h),
                  const _SectionLabel('Campus'),
                  SizedBox(height: 8.h),
                  const _CampusSettingsCard(),
                  SizedBox(height: 22.h),
                  const _SectionLabel('Account'),
                  SizedBox(height: 8.h),
                  const _AccountSettingsCard(),
                  SizedBox(height: 22.h),
                  const _SectionLabel('Help & support'),
                  SizedBox(height: 8.h),
                  _SettingsGroup(
                    children: [
                      _SettingsTile(
                        icon: Icons.support_agent_rounded,
                        accent: AppColors.primary,
                        title: 'Contact & feedback',
                        subtitle: 'Bugs, ideas and questions',
                        onTap: () => Navigator.push(
                          context,
                          AppPageRoute(
                            builder: (_) => const SupportScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 22.h),
                  const _SectionLabel('Legal'),
                  SizedBox(height: 8.h),
                  _SettingsGroup(
                    children: [
                      _SettingsTile(
                        icon: Icons.privacy_tip_outlined,
                        accent: AppColors.secondary,
                        title: 'Privacy Policy',
                        onTap: () =>
                            _openLink(context, '$kShopUrl/privacy.html'),
                      ),
                      _SettingsTile(
                        icon: Icons.description_outlined,
                        accent: AppColors.secondary,
                        title: 'Terms of Service',
                        onTap: () => _openLink(context, '$kShopUrl/terms.html'),
                      ),
                      _SettingsTile(
                        icon: Icons.lock_outline_rounded,
                        accent: AppColors.secondary,
                        title: 'No Refunds Policy',
                        onTap: () => _openLink(context, kNoRefundsPolicyUrl),
                      ),
                    ],
                  ),
                  SizedBox(height: 22.h),
                  const _SectionLabel('Danger zone'),
                  SizedBox(height: 8.h),
                  _DeleteAccountCard(onDelete: onDeleteAccount),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Header ─────────────────────────────────────────────────────────────────
class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 10.r, 20.r, 6.r),
      child: Row(
        children: [
          const AppBackButton(),
          SizedBox(width: 2.w),
          Expanded(
            child: Text(
              'Settings',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.heading2.copyWith(
                fontSize: 26.sp,
                letterSpacing: -0.5,
                height: 1.05,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Appearance picker ──────────────────────────────────────────────────────
/// System / Light / Dark, persisted instantly by [ThemeProvider].
///
/// Rendered only while [kThemeControlEnabled] is true — i.e. in debug builds
/// until every screen has been audited in light mode.
class _AppearanceSettingsCard extends StatelessWidget {
  const _AppearanceSettingsCard();

  static const List<_AppearanceOption> _options = [
    _AppearanceOption(
      mode: ThemeMode.system,
      label: 'System',
      icon: Icons.brightness_auto_rounded,
      accent: AppColors.secondary,
    ),
    _AppearanceOption(
      mode: ThemeMode.light,
      label: 'Light',
      icon: Icons.light_mode_rounded,
      accent: AppColors.amber,
    ),
    _AppearanceOption(
      mode: ThemeMode.dark,
      label: 'Dark',
      icon: Icons.dark_mode_rounded,
      accent: AppColors.primary,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider>();
    return AppCard(
      padding: EdgeInsets.all(4.r),
      child: Row(
        children: [
          for (final option in _options)
            Expanded(child: _option(option, provider)),
        ],
      ),
    );
  }

  Widget _option(_AppearanceOption option, ThemeProvider provider) {
    final selected = provider.mode == option.mode;
    final color = option.accent;

    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => provider.setMode(option.mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(vertical: 12.h),
          decoration: BoxDecoration(
            color:
                selected ? color.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color:
                  selected ? color.withValues(alpha: 0.4) : Colors.transparent,
            ),
          ),
          child: Column(
            children: [
              Icon(
                option.icon,
                size: 18.r,
                color:
                    selected ? AppColors.readable(color) : AppColors.textMuted,
              ),
              SizedBox(height: 5.h),
              Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTypography.fontFamily,
                  color: selected
                      ? AppColors.readable(color)
                      : AppColors.textSecondary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppearanceOption {
  final ThemeMode mode;
  final String label;
  final IconData icon;
  final Color accent;

  const _AppearanceOption({
    required this.mode,
    required this.label,
    required this.icon,
    required this.accent,
  });
}

// ─── Difficulty picker ──────────────────────────────────────────────────────
// The homepage reads the same provider, so the choice made here takes effect
// on the next solo quiz.
class _DifficultySettingsCard extends StatelessWidget {
  const _DifficultySettingsCard();

  static const Map<String, IconData> _icons = {
    'easy': Icons.eco_rounded,
    'medium': Icons.balance_rounded,
    'hard': Icons.local_fire_department_rounded,
  };

  static const Map<String, Color> _colors = {
    'easy': AppColors.correct,
    'medium': AppColors.amber,
    'hard': AppColors.wrong,
  };

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SoloDifficultyProvider>();
    final current = normalizeSoloDifficulty(provider.difficulty);

    return AppCard(
      padding: EdgeInsets.all(4.r),
      child: Row(
        children: [
          for (final id in kSoloDifficulties)
            Expanded(child: _option(id, provider, current)),
        ],
      ),
    );
  }

  Widget _option(String id, SoloDifficultyProvider provider, String current) {
    final selected = id == current;
    final color = _colors[id]!;
    final name = id[0].toUpperCase() + id.substring(1);

    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: GestureDetector(
        onTap: () => provider.setDifficulty(id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(vertical: 12.h),
          decoration: BoxDecoration(
            color:
                selected ? color.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color:
                  selected ? color.withValues(alpha: 0.4) : Colors.transparent,
            ),
          ),
          child: Column(
            children: [
              Icon(
                _icons[id],
                size: 18.r,
                color:
                    selected ? AppColors.readable(color) : AppColors.textMuted,
              ),
              SizedBox(height: 5.h),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTypography.fontFamily,
                  color: selected
                      ? AppColors.readable(color)
                      : AppColors.textSecondary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Campus picker ──────────────────────────────────────────────────────────
/// Inline campus picker — the only place a player changes campus.
///
/// The write is unchanged (`users/{uid}.university`), so entry eligibility and
/// the campus board re-derive exactly as before.
class _CampusSettingsCard extends StatefulWidget {
  const _CampusSettingsCard();

  @override
  State<_CampusSettingsCard> createState() => _CampusSettingsCardState();
}

class _CampusSettingsCardState extends State<_CampusSettingsCard> {
  String _current = '';
  String? _picked;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uni = await FirestoreService.instance.getCurrentUserUniversity();
      if (!mounted) return;
      setState(() {
        _current = uni ?? '';
        _picked = kNigerianUniversities.contains(uni) ? uni : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final picked = _picked;
    if (picked == null || _saving || picked == _current) return;
    setState(() => _saving = true);
    try {
      await FirestoreService.instance.updateUniversity(picked);
      if (!mounted) return;
      setState(() {
        _current = picked;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Campus saved.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
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
    final changed = _picked != null && _picked != _current;
    final subtitle = _loading
        ? 'Loading…'
        : (_current.isEmpty ? 'No campus selected yet' : 'Current: $_current');

    return AppCard(
      padding: EdgeInsets.all(14.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34.r,
                height: 34.r,
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Icon(
                  Icons.school_rounded,
                  color: AppColors.secondary,
                  size: 18.r,
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Your campus',
                      style: AppTypography.labelLarge.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceDim.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.divider),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: kNigerianUniversities.contains(_picked) ? _picked : null,
                isExpanded: true,
                dropdownColor: AppColors.surfaceAlt,
                icon: Icon(
                  Icons.expand_more_rounded,
                  color: AppColors.textMuted,
                  size: 20.r,
                ),
                hint: Text(
                  'Select your university',
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    color: AppColors.textMuted,
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextStyle(
                  fontFamily: AppTypography.fontFamily,
                  color: AppColors.textPrimary,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600,
                ),
                items: kNigerianUniversities
                    .map(
                      (u) => DropdownMenuItem(
                        value: u,
                        child: Text(
                          u,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _saving ? null : (v) => setState(() => _picked = v),
              ),
            ),
          ),
          SizedBox(height: 12.h),
          AppButton(
            label: 'Save campus',
            icon: const Icon(Icons.check_rounded),
            loading: _saving,
            onPressed: (changed && !_saving) ? _save : null,
          ),
        ],
      ),
    );
  }
}

// ─── Grouped rows ───────────────────────────────────────────────────────────
class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;

  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: 58.r),
            child: Container(height: 1, color: AppColors.divider),
          ),
        );
      }
      rows.add(children[i]);
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: Column(children: rows),
      ),
    );
  }
}

/// Account-level facts and destinations: the sign-in email (read-only; only a
/// verified account can reach Settings) and the purchase/code history.
class _AccountSettingsCard extends StatelessWidget {
  const _AccountSettingsCard();

  @override
  Widget build(BuildContext context) {
    final email = AuthService.instance.accountEmail;
    return _SettingsGroup(
      children: [
        _SettingsTile(
          icon: Icons.mark_email_read_rounded,
          accent: AppColors.correct,
          title: 'Email',
          subtitle: email.isEmpty ? 'Verified' : '$email · Verified',
          onTap: () {},
        ),
        _SettingsTile(
          icon: Icons.receipt_long_rounded,
          accent: AppColors.secondary,
          title: 'Purchases',
          subtitle: 'Codes and receipts',
          onTap: () => Navigator.push(
            context,
            AppPageRoute(builder: (_) => const PurchasesPage()),
          ),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.accent,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: accent.withValues(alpha: 0.10),
        highlightColor: accent.withValues(alpha: 0.06),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
          child: Row(
            children: [
              Container(
                width: 34.r,
                height: 34.r,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Icon(icon, color: accent, size: 17.r),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelLarge.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (subtitle != null) ...[
                      SizedBox(height: 2.h),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 8.w),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textMuted,
                size: 18.r,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Delete account ─────────────────────────────────────────────────────────
class _DeleteAccountCard extends StatelessWidget {
  final VoidCallback onDelete;

  const _DeleteAccountCard({required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.wrong.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.wrong.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34.r,
                height: 34.r,
                decoration: BoxDecoration(
                  color: AppColors.wrong.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.wrong,
                  size: 18.r,
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Delete account',
                      style: AppTypography.labelLarge.copyWith(
                        color: AppColors.wrong,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 3.h),
                    Text(
                      'Erases your profile, stats, coins and prizes. '
                      'This cannot be undone.',
                      style: AppTypography.bodySmall.copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          AppButton(
            label: 'Delete account',
            variant: AppButtonVariant.outline,
            color: AppColors.wrong,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

// ─── Shared bits ────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String title;

  const _SectionLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontFamily: AppTypography.fontFamily,
        color: AppColors.textSecondary,
        fontSize: 12.sp,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.9,
      ),
    );
  }
}

Future<void> _openLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final launched =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (launched) return;
  } catch (_) {
    // Fall through to the same snackbar as a refused launch.
  }
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Could not open the link. Check your connection.'),
    ),
  );
}
