import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../theme/app_theme.dart';

class AppSheet extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final bool dragHandle;
  final String? title;
  final double maxHeightFactor;

  const AppSheet({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.page,
      AppSpacing.sm,
      AppSpacing.page,
      AppSpacing.xl,
    ),
    this.dragHandle = true,
    this.title,
    this.maxHeightFactor = 0.88,
  });

  @override
  Widget build(BuildContext context) {
    final viewInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dragHandle)
            Padding(
              padding: EdgeInsets.only(top: AppSpacing.sm),
              child: FractionallySizedBox(
                widthFactor: 0.14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.all(Radius.circular(AppRadii.full)),
                  ),
                  child: const SizedBox(height: 4),
                ),
              ),
            ),
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.md,
                AppSpacing.page,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title!, style: AppTypography.titleLarge),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: padding.add(EdgeInsets.only(bottom: viewInset)),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
    ),
    builder: builder,
  );
}