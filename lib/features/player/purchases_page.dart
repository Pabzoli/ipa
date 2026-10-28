// lib/features/player/purchases_page.dart
//
// "Purchases" — the signed-in player's own website purchases and the codes
// they produced, newest first. Reached from Profile → Purchases (next to
// Redeem Code) and Settings → Account → Purchases.
//
// This is the self-serve replacement for "I lost my code": the success page
// shows it once, and the account now owns it. Everything here comes from the
// `getMyPurchases` callable — the client cannot read paymentIntents or
// redemptionCodes, and nothing is inferred that the server did not report.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_empty_state.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key});

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> {
  late Future<List<PurchaseEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = FirestoreService.instance.getMyPurchases();
  }

  /// Pull-to-refresh: re-runs the callable so a code redeemed on another
  /// device (or a webhook that just landed) shows up without a restart.
  Future<void> _reload() async {
    final future = FirestoreService.instance.getMyPurchases();
    setState(() => _future = future);
    try {
      await future;
    } catch (_) {
      // Rendered as the error state; swallowed so it is not an unhandled error.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: const AppBackButton(),
        title: Text(
          'Purchases',
          style: AppTypography.titleLarge.copyWith(fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<List<PurchaseEntry>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              );
            }

            return RefreshIndicator(
              color: AppColors.readable(AppColors.primary),
              backgroundColor: AppColors.surface,
              onRefresh: _reload,
              child: snapshot.hasError
                  ? _ScrollableCenter(
                      child: AppEmptyState(
                        icon: Icons.cloud_off_rounded,
                        title: 'Could not load purchases',
                        message: 'Check your connection and try again. Your '
                            'codes are safe — nothing has been lost.',
                        action: AppButton(
                          label: 'Try again',
                          size: AppButtonSize.small,
                          onPressed: _reload,
                        ),
                      ),
                    )
                  : (snapshot.data?.isEmpty ?? true)
                      ? _ScrollableCenter(
                          child: AppEmptyState(
                            icon: Icons.receipt_long_rounded,
                            title: 'No purchases yet',
                            message: 'Coins, Premium and leaderboard entries '
                                'you buy on our website appear here, with '
                                'their codes.',
                            action: AppButton(
                              label: 'Open the shop',
                              size: AppButtonSize.small,
                              onPressed: () =>
                                  launchUrl(Uri.parse(kShopUrl)),
                            ),
                          ),
                        )
                      : _PurchaseList(purchases: snapshot.data!),
            );
          },
        ),
      ),
    );
  }
}

// ─── List ───────────────────────────────────────────────────────────────────

class _PurchaseList extends StatelessWidget {
  final List<PurchaseEntry> purchases;

  const _PurchaseList({required this.purchases});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r),
      itemCount: purchases.length + 1,
      separatorBuilder: (_, __) => SizedBox(height: 10.h),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: 2.h),
            child: Text(
              'Newest first. A code only works on this account.',
              style: AppTypography.bodySmall,
            ),
          );
        }
        return _PurchaseCard(entry: purchases[index - 1]);
      },
    );
  }
}

// ─── One purchase ───────────────────────────────────────────────────────────

class _PurchaseCard extends StatelessWidget {
  final PurchaseEntry entry;

  const _PurchaseCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final status = _statusOf(entry);

    return AppCard(
      padding: EdgeInsets.all(14.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.productTitle,
                      style: AppTypography.titleMedium.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      '${_date(entry.createdAt)} · ${_money(entry)}',
                      style: AppTypography.bodySmall,
                    ),
                  ],
                ),
              ),
              SizedBox(width: 10.w),
              _StatusChip(status: status),
            ],
          ),
          if (entry.code != null) ...[
            SizedBox(height: 12.h),
            _CodeRow(code: entry.code!),
          ],
          if (entry.isRedeemed && entry.redeemedAt != null) ...[
            SizedBox(height: 8.h),
            Text(
              'Redeemed ${_date(entry.redeemedAt)}',
              style: AppTypography.bodySmall.copyWith(
                  color: AppColors.readable(AppColors.correct)),
            ),
          ],
          if (entry.isPending) ...[
            SizedBox(height: 8.h),
            Text(
              'Checkout was opened but no payment was confirmed. Nothing was '
              'charged here.',
              style: AppTypography.bodySmall,
            ),
          ],
          if (entry.isFulfilled && entry.code == null) ...[
            SizedBox(height: 8.h),
            Text(
              'Payment confirmed, but the code could not be loaded. Contact '
              'support with this reference: ${entry.txRef}',
              style: AppTypography.bodySmall
                  .copyWith(color: AppColors.readable(AppColors.amber)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The code plus a one-tap copy. The code is selectable too, so a failed
/// clipboard write (common in embedded webviews) is never a dead end.
class _CodeRow extends StatelessWidget {
  final String code;

  const _CodeRow({required this.code});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(12.r, 8.r, 4.r, 8.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: AppTypography.titleMedium.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy code',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.copy_rounded,
              size: 18.r,
              color: AppColors.secondary,
            ),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Code copied.')),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─── Status ─────────────────────────────────────────────────────────────────

class _PurchaseStatus {
  final String label;
  final Color color;
  final IconData icon;

  const _PurchaseStatus(this.label, this.color, this.icon);
}

/// Never claims more than the server reported: payment state comes from the
/// intent, code state from the code doc.
_PurchaseStatus _statusOf(PurchaseEntry entry) {
  if (entry.isPending) {
    return const _PurchaseStatus(
        'Awaiting payment', AppColors.amber, Icons.schedule_rounded);
  }
  if (entry.isRedeemed) {
    return _PurchaseStatus(
        'Redeemed', AppColors.textMuted, Icons.check_circle_outline_rounded);
  }
  if (entry.isRedeemable) {
    return const _PurchaseStatus('Ready to redeem', AppColors.correct,
        Icons.confirmation_number_outlined);
  }
  if (entry.isFulfilled && entry.code == null) {
    return const _PurchaseStatus(
        'Code unavailable', AppColors.wrong, Icons.error_outline_rounded);
  }
  if (entry.isFulfilled && entry.code != null && entry.codeStatus == null) {
    // The payment is definitely confirmed but the code's state could not be
    // read. Show the code (it may well still work) without claiming it is
    // unused.
    return const _PurchaseStatus(
        'Status unavailable', AppColors.amber, Icons.help_outline_rounded);
  }
  return _PurchaseStatus(
      'Pending', AppColors.textMuted, Icons.hourglass_empty_rounded);
}

class _StatusChip extends StatelessWidget {
  final _PurchaseStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: status.color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 12.r, color: status.color),
          SizedBox(width: 5.w),
          Text(
            status.label,
            style: AppTypography.labelSmall.copyWith(
              color: status.color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

class _ScrollableCenter extends StatelessWidget {
  final Widget child;

  const _ScrollableCenter({required this.child});

  @override
  Widget build(BuildContext context) {
    // Keeps pull-to-refresh usable on the empty and error states, which are
    // otherwise shorter than the viewport.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _date(DateTime? d) {
  if (d == null) return '—';
  final local = d.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// `₦4,000` for NGN, `USD 4,000` otherwise. Prices are whole naira today, but
/// the formatter keeps cents if the catalog ever gains them.
String _money(PurchaseEntry entry) {
  final raw = entry.amount == entry.amount.roundToDouble()
      ? entry.amount.toInt().toString()
      : entry.amount.toStringAsFixed(2);
  final parts = raw.split('.');
  final digits = parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  final formatted =
      parts.length > 1 ? '${grouped.toString()}.${parts[1]}' : grouped.toString();
  return entry.currency == 'NGN'
      ? '₦$formatted'
      : '${entry.currency} $formatted';
}
