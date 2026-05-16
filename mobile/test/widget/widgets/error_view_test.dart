import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/widgets/error_view.dart';

void main() {
  group('ErrorView', () {
    testWidgets('displays default error title', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ErrorView()),
        ),
      );

      expect(find.text('Something went wrong'), findsOneWidget);
    });

    testWidgets('displays error message when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ErrorView(message: 'Network timeout'),
          ),
        ),
      );

      expect(find.text('Network timeout'), findsOneWidget);
    });

    testWidgets('calls onRetry when retry button tapped', (tester) async {
      var retried = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorView(onRetry: () => retried = true),
          ),
        ),
      );

      expect(find.text('Try Again'), findsOneWidget);
      await tester.tap(find.text('Try Again'));
      expect(retried, isTrue);
    });

    testWidgets('does not show retry button when onRetry is null',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ErrorView()),
        ),
      );

      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('shows error icon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ErrorView()),
        ),
      );

      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });
  });
}
