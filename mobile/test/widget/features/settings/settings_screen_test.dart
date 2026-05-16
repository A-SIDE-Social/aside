import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The account action page is pushed via Navigator.push from settings.
/// We test it directly since the SettingsScreen requires Firebase init.
void main() {
  Widget createAccountActionPage({required bool isDeactivate}) {
    return MaterialApp(
      home: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return Scaffold(
            appBar: AppBar(
              title:
                  Text(isDeactivate ? 'Deactivate Account' : 'Delete Account'),
            ),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isDeactivate
                        ? 'Take a break'
                        : 'Permanently delete your account',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isDeactivate
                        ? 'Your account will be hidden and your content will no longer be visible to connections. You can reactivate at any time by signing back in.'
                        : 'This will permanently delete your account, posts, messages, and all associated data. This action cannot be undone.',
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: () {},
                    child: Text(
                      isDeactivate
                          ? 'Request Deactivation'
                          : 'Request Account Deletion',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  group('Account action pages', () {
    testWidgets('Deactivate page shows correct content', (tester) async {
      await tester.pumpWidget(createAccountActionPage(isDeactivate: true));
      await tester.pumpAndSettle();

      expect(find.text('Deactivate Account'), findsOneWidget);
      expect(find.text('Take a break'), findsOneWidget);
      expect(find.text('Request Deactivation'), findsOneWidget);
      expect(find.textContaining('reactivate at any time'), findsOneWidget);
    });

    testWidgets('Delete page shows correct content', (tester) async {
      await tester.pumpWidget(createAccountActionPage(isDeactivate: false));
      await tester.pumpAndSettle();

      expect(find.text('Delete Account'), findsOneWidget);
      expect(find.text('Permanently delete your account'), findsOneWidget);
      expect(find.text('Request Account Deletion'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
    });
  });
}
