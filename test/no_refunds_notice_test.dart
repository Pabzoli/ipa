import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/constants/app_constants.dart';
import 'package:quiz/core/widgets/no_refunds_note.dart';

// The no-refunds notice is the only in-app signal that purchases are final, so
// the copy is pinned to kNoRefundsNotice here: a softer rewrite of the widget
// text will fail this test rather than silently weakening the policy the user
// was shown at checkout.
void main() {
  Widget wrap(Widget content) => MaterialApp(
        home: ScreenUtilInit(
          designSize: const Size(390, 844),
          child: Scaffold(body: content),
        ),
      );

  testWidgets('NoRefundsNote states the policy in words', (tester) async {
    await tester.pumpWidget(wrap(const NoRefundsNote()));
    await tester.pumpAndSettle();

    expect(find.text('No refunds'), findsOneWidget);
    expect(find.text(kNoRefundsNotice), findsOneWidget);
    expect(find.textContaining('final sale'), findsOneWidget);
    expect(find.textContaining('No refunds'), findsWidgets);
  });

  testWidgets('NoRefundsNote omits the policy link by default',
      (tester) async {
    await tester.pumpWidget(wrap(const NoRefundsNote()));
    await tester.pumpAndSettle();

    expect(find.text('Read the full policy'), findsNothing);
    expect(find.text(kNoRefundsPolicyUrl), findsNothing);
  });

  testWidgets('NoRefundsNote exposes the hosted policy when asked',
      (tester) async {
    await tester.pumpWidget(wrap(const NoRefundsNote(showPolicyLink: true)));
    await tester.pumpAndSettle();

    expect(find.text('Read the full policy'), findsOneWidget);
  });

  testWidgets('NoRefundsNote has no acknowledgement gate that could be skipped',
      (tester) async {
    // Deliberately a notice and not a consent checkbox: a "I understand" step
    // the user can tap through without reading protects nothing, and it would
    // put a click target in front of the purchase CTA on every shop surface.
    await tester.pumpWidget(wrap(const NoRefundsNote(showPolicyLink: true)));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Radio), findsNothing);
  });

  testWidgets('kNoRefundsPolicyUrl points at the hosted no-refunds page',
      (tester) async {
    final uri = Uri.parse(kNoRefundsPolicyUrl);

    expect(uri.origin, Uri.parse(kShopUrl).origin);
    expect(uri.path, '/refund.html');
  });
}