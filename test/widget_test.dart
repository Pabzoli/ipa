import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/constants/app_constants.dart';
import 'package:quiz/core/widgets/shop_link_note.dart';

// Player-policy compliance test (website-redirect redesign): the shop URL must
// stay plain, non-interactive text with the only touch target being the "Copy"
// button — an accidental wrap in GestureDetector/InkWell or a stray
// url_launcher call will be caught here.
void main() {
  testWidgets(
      'ShopLinkNote renders the URL as non-tappable text and copies on demand',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ShopLinkNote()),
      ),
    );

    expect(find.text(kShopUrl), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(kShopUrl),
        matching: find.bySubtype<InkWell>(),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text(kShopUrl),
        matching: find.bySubtype<GestureDetector>(),
      ),
      findsNothing,
    );

    expect(find.byType(TextButton), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pump();

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    expect(data?.text, kShopUrl);

    expect(
      find.text('Website link copied — open it in your browser.'),
      findsOneWidget,
    );
  });

  testWidgets('ShopLinkNote supports a compact layout for bottom sheets',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ShopLinkNote(compact: true)),
      ),
    );

    expect(find.text(kShopUrl), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(kShopUrl),
        matching: find.bySubtype<GestureDetector>(),
      ),
      findsNothing,
    );
  });
}