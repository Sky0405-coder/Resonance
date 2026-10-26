import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/ui/widgets/common.dart';

Widget _app(double width) => MediaQuery(
  data: MediaQueryData(size: Size(width, 800)),
  child: MaterialApp(
    home: Scaffold(
      body: Shelf(title: 'Made for you', children: [for (var i = 0; i < 20; i++) Text('card $i')]),
    ),
  ),
);

ScrollPosition _position(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  testWidgets('wide shelves page with arrows', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(1200));
    await tester.pump();

    final back = find.byIcon(Icons.chevron_left);
    final forward = find.byIcon(Icons.chevron_right);
    expect(tester.widget<IconButton>(find.ancestor(of: back, matching: find.byType(IconButton))).onPressed, isNull);
    await tester.tap(forward);
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, greaterThan(0));
    expect(tester.widget<IconButton>(find.ancestor(of: back, matching: find.byType(IconButton))).onPressed, isNotNull);
  });

  testWidgets('shelves scroll by dragging with the mouse', (tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(600));
    expect(find.byIcon(Icons.chevron_right), findsNothing);

    final gesture = await tester.startGesture(tester.getCenter(find.text('card 1')), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, greaterThan(0));
  });
}
