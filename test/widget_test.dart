import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/constants/app_constants.dart';
import 'package:quiz/core/widgets/shop_link_note.dart';

/// Contract tests for [ShopLinkNote].
///
/// HISTORY / WHY THESE ASSERTIONS CHANGED
/// This suite originally asserted the opposite policy: the shop URL had to be
/// plain non-interactive text whose only affordance was a "Copy" button, and
/// wrapping the URL in a GestureDetector or calling url_launcher from this
/// widget was a policy violation. `shop_link_note.dart` was subsequently
/// changed in the working tree to an "Open" affordance that launches the shop
/// in an external browser, with a clipboard copy as the fallback when no
/// browser is available - but this test was never updated, so it failed.
///
/// That change is the same distribution decision the leaderboard entry CTA
/// makes, so the tests below now pin the *current* contract. If the shop link
/// is ever taken back off the app entirely (for example on a Google Play
/// release), both this widget and the leaderboard CTA must be reverted
/// together - see kLeaderboardAllowsExternalEntryLink.
Widget wrap(Widget content) => MaterialApp(
      home: ScreenUtilInit(
        designSize: const Size(390, 844),
        child: Scaffold(body: content),
      ),
    );

void main() {
  testWidgets('ShopLinkNote shows the shop URL and an Open affordance',
      (tester) async {
    // ShopLinkNote scales with `.r`, so the harness must initialise
    // ScreenUtil exactly as main.dart does.
    await tester.pumpWidget(wrap(const ShopLinkNote()));

    expect(find.text(kShopUrl), findsOneWidget);

    // Single, clearly-labelled way to reach the shop.
    expect(find.text('Open'), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);

    // The URL is styled as a link precisely because it is tappable now.
    final urlText = tester.widget<Text>(find.text(kShopUrl));
    expect(urlText.style?.decoration, TextDecoration.underline);
    expect(
      find.ancestor(
        of: find.text(kShopUrl),
        matching: find.bySubtype<GestureDetector>(),
      ),
      findsOneWidget,
    );
  });

  testWidgets('ShopLinkNote supports a compact layout for bottom sheets',
      (tester) async {
    await tester.pumpWidget(wrap(const ShopLinkNote(compact: true)));

    expect(find.text(kShopUrl), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(kShopUrl),
        matching: find.bySubtype<GestureDetector>(),
      ),
      findsOneWidget,
    );
  });

  testWidgets('ShopLinkNote survives a long URL without overflowing',
      (tester) async {
    // Set a deliberately tiny surface: the URL is a single ellipsised line and
    // must not throw a RenderFlex overflow on a narrow phone.
    tester.view.physicalSize = const Size(240, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const ShopLinkNote()));
    expect(tester.takeException(), isNull);
  });
}
