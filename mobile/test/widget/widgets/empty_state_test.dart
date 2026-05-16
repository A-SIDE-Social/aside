import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/widgets/empty_state.dart';

void main() {
  group('EmptyState', () {
    testWidgets('displays title text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.people,
              title: 'No connections yet',
            ),
          ),
        ),
      );

      expect(find.text('No connections yet'), findsOneWidget);
    });

    testWidgets('displays subtitle when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.people,
              title: 'No connections',
              subtitle: 'Share your invite code',
            ),
          ),
        ),
      );

      expect(find.text('Share your invite code'), findsOneWidget);
    });

    testWidgets('does not display subtitle when null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.people,
              title: 'No connections',
            ),
          ),
        ),
      );

      expect(find.byType(Text), findsOneWidget); // only title
    });

    testWidgets('displays action button when provided', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.people,
              title: 'Empty',
              actionLabel: 'Add',
              onAction: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Add'), findsOneWidget);
      await tester.tap(find.text('Add'));
      expect(tapped, isTrue);
    });

    testWidgets('does not display action button when label is null',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.people,
              title: 'Empty',
            ),
          ),
        ),
      );

      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('displays icon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.camera_alt,
              title: 'No photos',
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
    });
  });
}
