import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/widgets/avatar.dart';

void main() {
  group('Avatar', () {
    testWidgets('displays initial when no imageUrl', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Avatar(displayName: 'Alice'),
          ),
        ),
      );

      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('displays uppercase initial', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Avatar(displayName: 'bob'),
          ),
        ),
      );

      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('displays ? when displayName is empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Avatar(displayName: ''),
          ),
        ),
      );

      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('uses default size of 40', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Avatar(displayName: 'Alice'),
          ),
        ),
      );

      final container = tester.widget<Container>(find.byType(Container).first);
      final constraints = container.constraints;
      expect(constraints?.maxWidth, 40);
    });

    testWidgets('respects custom size', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Avatar(displayName: 'Alice', size: 80),
          ),
        ),
      );

      final container = tester.widget<Container>(find.byType(Container).first);
      expect(container.constraints?.maxWidth, 80);
    });
  });
}
