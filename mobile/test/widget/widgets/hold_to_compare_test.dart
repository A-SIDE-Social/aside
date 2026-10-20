import 'package:aside/widgets/hold_to_compare.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget photo({bool enabled = true}) => MaterialApp(
        home: Scaffold(
          body: HoldToCompare(
            enabled: enabled,
            builder: (original) => SizedBox(
              width: 300,
              height: 300,
              child: Text(original ? 'unfiltered pixels' : 'edited pixels'),
            ),
          ),
        ),
      );

  testWidgets('hold compares only until released or cancelled', (tester) async {
    await tester.pumpWidget(photo());
    final gesture = await tester.startGesture(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('unfiltered pixels'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(find.text('edited pixels'), findsOneWidget);

    final cancelled = await tester.startGesture(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 600));
    await cancelled.cancel();
    await tester.pump();
    expect(find.text('edited pixels'), findsOneWidget);
  });

  testWidgets('dragging and the Original preset do not start comparison',
      (tester) async {
    await tester.pumpWidget(photo());
    await tester.drag(find.byType(HoldToCompare), const Offset(150, 0));
    await tester.pump();
    expect(find.text('Original'), findsNothing);
    await tester.pumpWidget(photo(enabled: false));
    await tester.longPress(find.byType(HoldToCompare));
    expect(find.text('Original'), findsNothing);
  });
}
