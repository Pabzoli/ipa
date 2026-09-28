import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/firestore_service.dart';
import 'stake_screen.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_empty_state.dart';
import '../../core/widgets/app_page_route.dart';

/// Anime selection screen used by Quick Match and Create/Rival Challenge flows.
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

  static const List<List<Color>> _palettes = [
    [Color(0xFF6D5DFB), Color(0xFF4338CA)],
    [Color(0xFF38BDF8), Color(0xFF0369A1)],
    [Color(0xFFF59E0B), Color(0xFFB45309)],
    [Color(0xFF34D399), Color(0xFF047857)],
    [Color(0xFFF472B6), Color(0xFFBE185D)],
    [Color(0xFFA78BFA), Color(0xFF2563EB)],
    [Color(0xFFFB7185), Color(0xFF9F1239)],
    [Color(0xFF22D3EE), Color(0xFF155E75)],
  ];

  String _emoji(String title) =>
      _emojiMap[title.toLowerCase().trim()] ?? '✨';

  List<Color> _palette(String title) {
    final index = title.codeUnits.fold<int>(0, (sum, value) => sum + value) %
        _palettes.length;
    return _palettes[index];
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
      if (mounted) {
        setState(() => _selectedTitle = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: Column(
          children: [
            _AnimeTopBar(
              hasOpponent: _hasOpponent,
              opponentUsername: widget.opponentUsername,
              enabled: _selectedTitle == null,
              onBack: () => Navigator.pop(context),
            ),
            Expanded(
              child: _loading
                  ? const _AnimeLoadingState()
                  : _error != null
                      ? _AnimeErrorState(
                          message: _error!,
                          onRetry: _fetchTitles,
                        )
                      : _titles.isEmpty
                          ? const _AnimeEmptyState()
                          : RefreshIndicator(
                              color: AppColors.primary,
                              backgroundColor: AppColors.surface,
                              strokeWidth: 2.2,
                              onRefresh: _fetchTitles,
                              child: CustomScrollView(
                                physics: const BouncingScrollPhysics(
                                  parent: AlwaysScrollableScrollPhysics(),
                                ),
                                slivers: [
                                  SliverToBoxAdapter(
                                    child: _SelectionHero(
                                      hasOpponent: _hasOpponent,
                                      opponentUsername:
                                          widget.opponentUsername,
                                    ),
                                  ),
                                  SliverPadding(
                                    padding: EdgeInsets.fromLTRB(
                                      16.r,
                                      2.r,
                                      16.r,
                                      32.r,
                                    ),
                                    sliver: SliverGrid(
                                      delegate: SliverChildBuilderDelegate(
                                        (_, index) {
                                          final title = _titles[index];
                                          return _AnimeCard(
                                            title: title,
                                            emoji: _emoji(title),
                                            gradient: _palette(title),
                                            selected:
                                                _selectedTitle == title,
                                            disabled: _selectedTitle != null &&
                                                _selectedTitle != title,
                                            onTap: () => _select(title),
                                          );
                                        },
                                        childCount: _titles.length,
                                      ),
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        mainAxisSpacing: 14.h,
                                        crossAxisSpacing: 14.w,
                                        childAspectRatio: 0.92,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimeTopBar extends StatelessWidget {
  final bool hasOpponent;
  final String? opponentUsername;
  final bool enabled;
  final VoidCallback onBack;

  const _AnimeTopBar({
    required this.hasOpponent,
    required this.opponentUsername,
    required this.enabled,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 10.r, 16.r, 8.r),
      child: Row(
        children: [
          IconButton(
            onPressed: enabled ? onBack : null,
            splashRadius: 22,
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary,
              size: 19.r,
            ),
          ),
          SizedBox(width: 2.w),
          Expanded(
            child: Text(
              'Create challenge',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 26.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                height: 1.05,
              ),
            ),
          ),
          if (hasOpponent) _OpponentPill(username: opponentUsername!),
        ],
      ),
    );
  }
}

class _OpponentPill extends StatelessWidget {
  final String username;

  const _OpponentPill({required this.username});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: 132.w),
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999.r),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bolt_rounded,
            color: AppColors.primary,
            size: 14.r,
          ),
          SizedBox(width: 5.w),
          Flexible(
            child: Text(
              '@$username',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 11.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionHero extends StatelessWidget {
  final bool hasOpponent;
  final String? opponentUsername;

  const _SelectionHero({
    required this.hasOpponent,
    required this.opponentUsername,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16.r, 6.r, 16.r, 14.r),
      child: Container(
        padding: EdgeInsets.all(16.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 46.r,
              height: 46.r,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(13.r),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                color: AppColors.primary,
                size: 22.r,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Choose your battleground',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                      height: 1.2,
                    ),
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    hasOpponent
                        ? 'Challenge @$opponentUsername in an anime you know best.'
                        : 'Pick an anime and move straight into your challenge.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.sp,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
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

class _AnimeCard extends StatefulWidget {
  final String title;
  final String emoji;
  final List<Color> gradient;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _AnimeCard({
    required this.title,
    required this.emoji,
    required this.gradient,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  @override
  State<_AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<_AnimeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
      lowerBound: 0,
      upperBound: 0.035,
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.gradient.first;
    final muted = widget.disabled;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: muted ? 0.40 : 1,
      child: ScaleTransition(
        scale: Tween<double>(
          begin: 1,
          end: 0.965,
        ).animate(_press),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22.r),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: widget.selected ? 0.24 : 0.15),
                widget.gradient.last.withValues(
                  alpha: widget.selected ? 0.11 : 0.045,
                ),
              ],
            ),
            border: Border.all(
              color: widget.selected
                  ? AppColors.primary
                  : accent.withValues(alpha: 0.22),
              width: widget.selected ? 1.7 : 1,
            ),
            boxShadow: [
              if (widget.selected)
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.18),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: InkWell(
            onTap: muted ? null : () => widget.onTap(),
            borderRadius: BorderRadius.circular(22.r),
            child: Stack(
              children: [
                Positioned(
                  right: -24.w,
                  top: -28.h,
                  child: _GlowOrb(
                    color: accent,
                    size: 92,
                  ),
                ),
                Positioned(
                  left: -34.w,
                  bottom: -38.h,
                  child: _GlowOrb(
                    color: widget.gradient.last,
                    size: 100,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(13.r, 13.r, 12.r, 12.r),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.topRight,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 170),
                          padding: EdgeInsets.symmetric(
                            horizontal: 7.r,
                            vertical: 4.r,
                          ),
                          decoration: BoxDecoration(
                            color: (widget.selected
                                    ? AppColors.primary
                                    : AppColors.surface)
                                .withValues(
                              alpha: widget.selected ? 0.16 : 0.55,
                            ),
                            borderRadius: BorderRadius.circular(9.r),
                            border: Border.all(
                              color: (widget.selected
                                      ? AppColors.primary
                                      : AppColors.divider)
                                  .withValues(alpha: 0.8),
                            ),
                          ),
                          child: Icon(
                            widget.selected
                                ? Icons.check_rounded
                                : Icons.arrow_outward_rounded,
                            size: 13.r,
                            color: widget.selected
                                ? AppColors.primary
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 180),
                            scale: widget.selected ? 1.08 : 1,
                            child: Container(
                              width: 74.w,
                              height: 74.h,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent.withValues(alpha: 0.09),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.16),
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  widget.emoji,
                                  style: TextStyle(fontSize: 38.sp),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 8.h),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w800,
                            height: 1.14,
                            letterSpacing: -0.15,
                          ),
                        ),
                      ),
                      SizedBox(height: 6.h),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.selected ? 'Selected' : 'Tap to choose',
                          style: TextStyle(
                            color: widget.selected
                                ? AppColors.primary
                                : AppColors.textMuted,
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final Color color;
  final double size;

  const _GlowOrb({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: 0.16),
            color.withValues(alpha: 0.0),
          ],
        ),
      ),
    );
  }
}

class _AnimeLoadingState extends StatelessWidget {
  const _AnimeLoadingState();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16.r, 12.r, 16.r, 18.r),
            child: Container(
              height: 82.h,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(22.r),
                border: Border.all(color: AppColors.divider),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16.r, 0.r, 16.r, 32.r),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (_, index) => _SkeletonCard(index: index),
              childCount: 8,
            ),
            gridDelegate:
                SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 14.h,
              crossAxisSpacing: 14.w,
              childAspectRatio: 0.92,
            ),
          ),
        ),
      ],
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  final int index;

  const _SkeletonCard({required this.index});

  @override
  Widget build(BuildContext context) {
    final opacity = 0.34 + (index % 3) * 0.08;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: opacity, end: opacity + 0.12),
      duration: Duration(milliseconds: 700 + index * 70),
      curve: Curves.easeInOut,
      builder: (_, value, __) {
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: value),
            borderRadius: BorderRadius.circular(22.r),
            border: Border.all(
              color: AppColors.divider.withValues(alpha: 0.7),
            ),
          ),
        );
      },
    );
  }
}

class _AnimeEmptyState extends StatelessWidget {
  const _AnimeEmptyState();

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      icon: Icons.auto_awesome_outlined,
      title: 'No anime available',
      message: 'There are no anime titles available for challenges yet.',
    );
  }
}

class _AnimeErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _AnimeErrorState({
    required this.message,
    required this.onRetry,
  });

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