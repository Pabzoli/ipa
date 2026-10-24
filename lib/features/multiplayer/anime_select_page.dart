import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/firestore_service.dart';
import 'stake_screen.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_empty_state.dart';
import '../../core/widgets/app_page_route.dart';

/// Anime selection screen used by Quick Match and Create/Rival Challenge flows.
///
/// One job: pick the anime. Cards are plain and tappable; the only state is the
/// pending selection (which disables the grid while the next screen opens).
class AnimeSelectPage extends StatefulWidget {
  final void Function(String title)? onSelect;
  final String? opponentUid;
  final String? opponentUsername;

  const AnimeSelectPage({
    super.key,
    this.onSelect,
    this.opponentUid,
    this.opponentUsername,
  });

  @override
  State<AnimeSelectPage> createState() => _AnimeSelectPageState();
}

class _AnimeSelectPageState extends State<AnimeSelectPage> {
  List<String> _titles = [];
  bool _loading = true;
  String? _error;
  String? _selectedTitle;

  static const Map<String, String> _emojiMap = {
    'naruto': '🍜',
    'one piece': '🏴‍☠️',
    'dragon ball z': '💥',
    'attack on titan': '⚔️',
    'demon slayer': '🗡️',
    'my hero academia': '🦸',
    'death note': '📓',
    'fullmetal alchemist': '⚗️',
    'hunter x hunter': '🎯',
    'jujutsu kaisen': '🌀',
    'bleach': '🔱',
    'sword art online': '🗡',
    'fairy tail': '🧙',
    'black clover': '🍀',
    'one punch man': '👊',
    'tokyo ghoul': '👁️',
    'vinland saga': '🪓',
    'chainsaw man': '🔪',
  };

  static const List<Color> _accents = [
    Color(0xFF6D5DFB),
    Color(0xFF38BDF8),
    Color(0xFFF59E0B),
    Color(0xFF34D399),
    Color(0xFFF472B6),
    Color(0xFFA78BFA),
    Color(0xFFFB7185),
    Color(0xFF22D3EE),
  ];

  String _emoji(String title) =>
      _emojiMap[title.toLowerCase().trim()] ?? '✨';

  Color _accent(String title) {
    final index = title.codeUnits.fold<int>(0, (sum, value) => sum + value) %
        _accents.length;
    return _accents[index];
  }

  bool get _hasOpponent =>
      widget.opponentUid?.trim().isNotEmpty == true &&
      widget.opponentUsername?.trim().isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _fetchTitles();
  }

  Future<void> _fetchTitles() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final titles = await FirestoreService.instance.fetchAnimeTitles();
      if (!mounted) return;
      setState(() {
        _titles = titles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _select(String title) {
    if (_selectedTitle != null) return;

    setState(() => _selectedTitle = title);

    if (widget.onSelect != null) {
      Future.delayed(const Duration(milliseconds: 170), () {
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onSelect!(title);
      });
      return;
    }

    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => StakeScreen(
          animeTitle: title,
          opponentUid: widget.opponentUid,
          opponentUsername: widget.opponentUsername,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() => _selectedTitle = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              subtitle: _hasOpponent
                  ? 'vs @${widget.opponentUsername}'
                  : null,
              enabled: _selectedTitle == null,
              onBack: () => Navigator.pop(context),
            ),
            Expanded(
              child: _loading
                  ? const _LoadingGrid()
                  : _error != null
                      ? _ErrorState(message: _error!, onRetry: _fetchTitles)
                      : _titles.isEmpty
                          ? const _EmptyState()
                          : RefreshIndicator(
                              color: AppColors.primary,
                              backgroundColor: AppColors.surface,
                              strokeWidth: 2.2,
                              onRefresh: _fetchTitles,
                              child: GridView.builder(
                                physics: const AlwaysScrollableScrollPhysics(
                                  parent: BouncingScrollPhysics(),
                                ),
                                padding: EdgeInsets.fromLTRB(
                                    16.r, 6.r, 16.r, 32.r),
                                itemCount: _titles.length,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 12.h,
                                  crossAxisSpacing: 12.w,
                                  childAspectRatio: 1.02,
                                ),
                                itemBuilder: (_, index) {
                                  final title = _titles[index];
                                  return _AnimeTile(
                                    title: title,
                                    emoji: _emoji(title),
                                    accent: _accent(title),
                                    selected: _selectedTitle == title,
                                    disabled: _selectedTitle != null &&
                                        _selectedTitle != title,
                                    onTap: () => _select(title),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String? subtitle;
  final bool enabled;
  final VoidCallback onBack;

  const _TopBar({
    required this.subtitle,
    required this.enabled,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(6.r, 8.r, 16.r, 8.r),
      child: Row(
        children: [
          IconButton(
            onPressed: enabled ? onBack : null,
            splashRadius: 20,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary,
              size: 19.r,
            ),
          ),
          SizedBox(width: 2.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Pick your anime',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                    height: 1.1,
                  ),
                ),
                if (subtitle != null) ...[
                  SizedBox(height: 2.h),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A plain, tappable anime tile: emoji, title, and a check when selected.
class _AnimeTile extends StatelessWidget {
  final String title;
  final String emoji;
  final Color accent;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _AnimeTile({
    required this.title,
    required this.emoji,
    required this.accent,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: disabled ? 0.4 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: selected ? 0.24 : 0.14),
              accent.withValues(alpha: selected ? 0.10 : 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : accent.withValues(alpha: 0.20),
            width: selected ? 1.7 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: disabled ? null : onTap,
            borderRadius: BorderRadius.circular(AppRadii.xl),
            child: Padding(
              padding: EdgeInsets.all(14.r),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(
                      height: 18.r,
                      width: 18.r,
                      child: selected
                          ? Icon(
                              Icons.check_circle_rounded,
                              color: AppColors.primary,
                              size: 18.r,
                            )
                          : null,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 62.r,
                    height: 62.r,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withValues(alpha: 0.10),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Text(emoji, style: TextStyle(fontSize: 30.sp)),
                  ),
                  SizedBox(height: 12.h),
                  Text(
                    title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16.r, 6.r, 16.r, 32.r),
      itemCount: 8,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12.h,
        crossAxisSpacing: 12.w,
        childAspectRatio: 1.02,
      ),
      itemBuilder: (_, __) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(color: AppColors.divider),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      icon: Icons.auto_awesome_outlined,
      title: 'No anime available',
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.cloud_off_rounded,
      title: 'Couldn’t load anime',
      message: message,
      action: AppButton(
        label: 'Try again',
        icon: const Icon(Icons.refresh_rounded),
        variant: AppButtonVariant.outline,
        size: AppButtonSize.small,
        onPressed: onRetry,
      ),
    );
  }
}
