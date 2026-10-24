import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/share_links.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/share_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_page_route.dart';
import 'payout_claim_page.dart';

const List<Color> _rankColors = [AppColors.gold, AppColors.silver, AppColors.bronze];
const List<String> _medals = ['🥇', '🥈', '🥉'];

String _fmtNaira(double amount) {
  final n = amount.toInt().toString();
  final b = StringBuffer();
  for (int i = 0; i < n.length; i++) {
    if (i > 0 && (n.length - i) % 3 == 0) b.write(',');
    b.write(n[i]);
  }
  return b.toString();
}

/// Monday announcement of last week's prize winners.
///
/// Shown automatically by [_AnnouncementGate] in main.dart and reachable from
/// My Prizes. It stays open until the player closes it or shares the results.
class WinnerAnnouncementPage extends StatefulWidget {
  const WinnerAnnouncementPage({super.key, required this.result});

  final LastWeekResult result;

  @override
  State<WinnerAnnouncementPage> createState() => _WinnerAnnouncementPageState();
}

class _WinnerAnnouncementPageState extends State<WinnerAnnouncementPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceCtrl;
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideUp;

  @override
  void initState() {
    super.initState();

    _entranceCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    );
    _fadeIn = CurvedAnimation(
      parent: _entranceCtrl,
      curve:  const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end:   Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entranceCtrl,
      curve:  const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
    ));

    _entranceCtrl.forward();
  }

  Animation<double> _rowAnim(int index) {
    final s = (0.25 + index * 0.08).clamp(0.0, 0.8);
    final e = (s + 0.3).clamp(0.2, 1.0);
    return CurvedAnimation(
      parent: _entranceCtrl,
      curve:  Interval(s, e, curve: Curves.easeOutCubic),
    );
  }

  void _dismiss() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _weekRange() {
    final parts = widget.result.weekId.split('-');
    if (parts.length < 3) return widget.result.weekId;
    final mon = DateTime(
      int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]),
    );
    final sun = mon.add(const Duration(days: 6));
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final s = '${mo[mon.month - 1]} ${mon.day}';
    final e = mon.month == sun.month
        ? '${sun.day}'
        : '${mo[sun.month - 1]} ${sun.day}';
    return '$s–$e, ${mon.year}';
  }

  Future<void> _share() async {
    HapticFeedback.lightImpact();
    final winners = widget.result.winners;
    if (winners.isEmpty) return;
    final lines = winners.take(3).map((p) {
      final medal = p.rank <= 3 ? _medals[p.rank - 1] : '#${p.rank}';
      return '$medal ${p.username} (${p.university}) — ₦${_fmtNaira(p.prizeAmount)}';
    }).toList();
    // Native sheet (WhatsApp, Instagram, messages, ...) instead of a hard
    // WhatsApp-only hand-off: the same text, but the player picks the channel.
    await ShareService.instance.shareText(
      context,
      text: winnersShareMessage(
        weekRange: _weekRange(),
        winnerLines: lines,
      ),
      subject: 'AnimeQuiz champions — ${_weekRange()}',
    );
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final winners = widget.result.winners.take(5).toList();
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    PrizeWinner? myWin;
    if (myUid != null) {
      for (final w in winners) {
        if (w.uid == myUid) {
          myWin = w;
          break;
        }
      }
    }

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeIn,
          child: SlideTransition(
            position: _slideUp,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0,
                    ),
                    child: _CloseButton(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        _dismiss();
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.page,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Header(
                          weekRange:    _weekRange(),
                          totalNaira:   widget.result.totalNaira,
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        if (myWin != null) ...[
                          _YourResultCard(
                            rank:      myWin.rank,
                            formatted: _fmtNaira(myWin.prizeAmount),
                            onClaim:   () {
                              HapticFeedback.mediumImpact();
                              Navigator.of(context).push(
                                AppPageRoute(
                                  builder: (_) => PayoutClaimPage(
                                    weekId: widget.result.weekId,
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: AppSpacing.xl),
                        ],
                        Text(
                          'WINNERS',
                          style: AppTypography.labelSmall,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        ...winners.asMap().entries.map(
                          (e) => Padding(
                            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                            child: _WinnerRow(
                              key:       ValueKey(e.value.uid),
                              winner:    e.value,
                              isMe:      myUid != null && e.value.uid == myUid,
                              formatted: _fmtNaira(e.value.prizeAmount),
                              animation: _rowAnim(e.key),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppButton(
                        label:     'Share results',
                        variant:   AppButtonVariant.text,
                        color:     AppColors.textSecondary,
                        icon:      const Icon(Icons.share_rounded),
                        onPressed: _share,
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

// ─── Close button ─────────────────────────────────────────────────────────────
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Close announcement',
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(
          side: BorderSide(color: AppColors.divider),
        ),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width:  36.r,
            height: 36.r,
            child: Icon(
              Icons.close_rounded,
              size:  19.r,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.weekRange, required this.totalNaira});

  final String weekRange;
  final double totalNaira;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width:  72.r,
          height: 72.r,
          decoration: BoxDecoration(
            shape:  BoxShape.circle,
            color:  AppColors.gold.withValues(alpha: 0.12),
            border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
          ),
          child: Icon(Icons.emoji_events_rounded,
              color: AppColors.gold, size: 36.r),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          "Last week's champions",
          style: AppTypography.heading2,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(weekRange, style: AppTypography.bodyMedium),
        if (totalNaira > 0) ...[
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical:   AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color:        AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.full),
              border:       Border.all(color: AppColors.divider),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text:  'Prize pool  ',
                    style: AppTypography.bodySmall,
                  ),
                  TextSpan(
                    text:  '₦${_fmtNaira(totalNaira)}',
                    style: AppTypography.labelLarge
                        .copyWith(color: AppColors.gold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Your Result (winner-only) ────────────────────────────────────────────────
class _YourResultCard extends StatelessWidget {
  const _YourResultCard({
    required this.rank,
    required this.formatted,
    required this.onClaim,
  });

  final int          rank;
  final String       formatted;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding:     const EdgeInsets.all(AppSpacing.lg),
      color:       AppColors.gold.withValues(alpha: 0.08),
      borderColor: AppColors.gold.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'YOU PLACED #$rank',
            style: AppTypography.labelSmall.copyWith(color: AppColors.gold),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '₦$formatted',
            style: AppTypography.heading1.copyWith(color: AppColors.gold),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label:     'Claim prize',
            size:      AppButtonSize.large,
            onPressed: onClaim,
          ),
        ],
      ),
    );
  }
}

// ─── Winner Row ───────────────────────────────────────────────────────────────
class _WinnerRow extends StatelessWidget {
  const _WinnerRow({
    super.key,
    required this.winner,
    required this.isMe,
    required this.formatted,
    required this.animation,
  });

  final PrizeWinner       winner;
  final bool              isMe;
  final String            formatted;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final isTop3    = winner.rank >= 1 && winner.rank <= 3;
    final rankColor = isTop3 ? _rankColors[winner.rank - 1] : AppColors.textMuted;

    final row = AppCard(
      padding:     EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical:   AppSpacing.md,
      ),
      accentColor: isTop3 ? rankColor : null,
      borderColor: isMe ? AppColors.gold.withValues(alpha: 0.4) : null,
      child: Row(
        children: [
          _RankBadge(rank: winner.rank, color: rankColor),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        winner.username,
                        style: AppTypography.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: AppSpacing.sm),
                      const _YouTag(),
                    ],
                  ],
                ),
                if (winner.university.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    winner.university,
                    style: AppTypography.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '₦$formatted',
            style: AppTypography.labelLarge.copyWith(
              color: isTop3 ? rankColor : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );

    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end:   Offset.zero,
        ).animate(animation),
        child: row,
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank, required this.color});

  final int   rank;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width:  32.r,
      height: 32.r,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape:  BoxShape.circle,
        color:  color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '$rank',
        style: AppTypography.labelMedium.copyWith(
          color:      color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _YouTag extends StatelessWidget {
  const _YouTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color:        AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadii.xs),
      ),
      child: Text(
        'YOU',
        style: AppTypography.labelSmall.copyWith(color: AppColors.primary),
      ),
    );
  }
}
