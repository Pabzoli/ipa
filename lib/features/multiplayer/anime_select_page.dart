import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/firestore_service.dart';
import 'bet_screen.dart';

// ─── Anime selection — step 1 of Create Challenge flow ───────────────────────
// What changed: Previously the anime title was passed into BetScreen from
// somewhere upstream (unclear). Now there's a dedicated screen that fetches
// available anime titles from Firestore (so the list stays in sync with your
// questions collection), displays them in a grid, and handles the loading/
// error/empty states properly.
class AnimeSelectPage extends StatefulWidget {
  const AnimeSelectPage({super.key});

  @override
  State<AnimeSelectPage> createState() => _AnimeSelectPageState();
}

class _AnimeSelectPageState extends State<AnimeSelectPage> {
  List<String> _all = [];
  List<String> _filtered = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  final _searchCtrl = TextEditingController();

  // Maps anime titles to emojis for visual flair.
  // Keys are lowercase to match Firestore animeTitle field.
  static const Map<String, String> _emojiMap = {
    'naruto':              '🍜',
    'one piece':           '🏴‍☠️',
    'dragon ball z':       '💥',
    'attack on titan':     '⚔️',
    'demon slayer':        '🗡️',
    'my hero academia':    '🦸',
    'death note':          '📓',
    'fullmetal alchemist': '⚗️',
    'hunter x hunter':    '🎯',
    'jujutsu kaisen':      '🌀',
    'bleach':              '🔱',
    'sword art online':    '🗡',
    'fairy tail':          '🧙',
    'black clover':        '🍀',
    'one punch man':       '👊',
    'tokyo ghoul':         '👁️',
    'vinland saga':        '🪓',
    'chainsaw man':        '🔪',
  };

  String _emoji(String title) =>
      _emojiMap[title.toLowerCase()] ?? '✨';

  @override
  void initState() {
    super.initState();
    _fetchTitles();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchTitles() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final titles = await FirestoreService.instance.fetchAnimeTitles();
      if (!mounted) return;
      setState(() {
        _all = titles;
        _filtered = titles;
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

  void _onSearch(String q) {
    setState(() {
      _query = q;
      _filtered = _all
          .where((t) => t.toLowerCase().contains(q.toLowerCase()))
          .toList();
    });
  }

  void _select(String title) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => FadeTransition(
          opacity: a,
          child: BetScreen(animeTitle: title),
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── App bar ──────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded,
                          color: AppColors.textPrimary, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pick an Anime',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          Text(
                            'Step 1 of 2 — Select your battlefield',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Search bar ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: _onSearch,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Search anime…',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      prefixIcon: Icon(Icons.search_rounded,
                          color: AppColors.textMuted, size: 20),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                    ),
                  ),
                ),
              ),

              // ── Grid / loading / error ────────────────────────────────
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return _LoadingGrid();
    if (_error != null) return _ErrorState(error: _error!, onRetry: _fetchTitles);
    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🤔', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              _query.isEmpty
                  ? 'No anime available yet'
                  : 'No results for "$_query"',
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.1,
      ),
      itemCount: _filtered.length,
      itemBuilder: (_, i) => _AnimeCard(
        key: ValueKey(_filtered[i]),
        title: _filtered[i],
        emoji: _emoji(_filtered[i]),
        onTap: () => _select(_filtered[i]),
      ),
    );
  }
}

// ── Individual anime card ──────────────────────────────────────────────────────
// Why: Grid cards are much faster to scan than a list. The emoji + title
// combination is memorable. The scale animation on tap makes it feel snappy.
class _AnimeCard extends StatefulWidget {
  final String title;
  final String emoji;
  final VoidCallback onTap;

  const _AnimeCard({
    super.key,
    required this.title,
    required this.emoji,
    required this.onTap,
  });

  @override
  State<_AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<_AnimeCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  // Deterministic color per card based on title hash — consistent and vibrant
  static const _palettes = [
    [Color(0xFF7C3AED), Color(0xFF4F46E5)],
    [Color(0xFF0EA5E9), Color(0xFF0284C7)],
    [Color(0xFFD97706), Color(0xFFB45309)],
    [Color(0xFF059669), Color(0xFF047857)],
    [Color(0xFFDB2777), Color(0xFFBE185D)],
    [Color(0xFF7C3AED), Color(0xFF0EA5E9)],
  ];

  List<Color> get _gradient {
    final idx = widget.title.hashCode.abs() % _palettes.length;
    return _palettes[idx];
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: GestureDetector(
        onTapDown: (_) => _ctrl.forward(),
        onTapUp: (_) {
          _ctrl.reverse();
          widget.onTap();
        },
        onTapCancel: () => _ctrl.reverse(),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                _gradient[0].withOpacity(0.2),
                _gradient[1].withOpacity(0.08),
              ],
            ),
            border: Border.all(
              color: _gradient[0].withOpacity(0.35),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(widget.emoji,
                  style: const TextStyle(fontSize: 36)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Loading skeleton grid ──────────────────────────────────────────────────────
class _LoadingGrid extends StatefulWidget {
  @override
  State<_LoadingGrid> createState() => _LoadingGridState();
}

class _LoadingGridState extends State<_LoadingGrid>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (_, child) {
        // Only the color lerp is here — grid structure is not rebuilt
        final shimmerColor = Color.lerp(
          AppColors.surface,
          AppColors.divider,
          _shimmer.value * 0.5,
        )!;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.1,
          ),
          itemCount: 8,
          itemBuilder: (_, __) => Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: shimmerColor,
            ),
          ),
        );
      },
    );
  }
}

// ── Error state ────────────────────────────────────────────────────────────────
class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('😵', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                error,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded,
                    color: AppColors.primary),
                label: const Text(
                  'Try Again',
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
            ],
          ),
        ),
      );
}