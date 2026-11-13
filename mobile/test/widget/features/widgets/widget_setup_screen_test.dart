import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aside/features/widgets/widget_setup_screen.dart';

void main() {
  testWidgets('widget setup remains readable at large text sizes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: const WidgetSetupScreen(),
    )));
    expect(find.text('Home Screen widgets'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1100));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
