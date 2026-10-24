import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/theme/app_theme.dart';
import 'package:quiz/core/widgets/app_card.dart';

Widget wrap(Widget child) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (_, __) => MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  // Regression: the accent used to be a heavier LEFT border on a
  // `BorderRadius`d card. Flutter asserts "A borderRadius can only be given on
  // borders with uniform colors" during paint, and the thrown paint takes the
  // card's whole child with it — the card outlined but every winner name and
  // prize vanished.
  testWidgets('AppCard paints its child when accentColor is set',
      (tester) async {
    await tester.pumpWidget(wrap(
      const AppCard(
        accentColor: AppColors.gold,
        child: Text('Player One'),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Player One'), findsOneWidget);
    expect(tester.getSize(find.text('Player One')).width, greaterThan(0));
  });
}
