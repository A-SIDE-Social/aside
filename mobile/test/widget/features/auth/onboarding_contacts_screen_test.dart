import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/features/auth/onboarding_contacts_screen.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createOnboardingScreen() {
    final user = User.fromJson(userJson(
      id: 'me-1',
      displayName: 'New User',
    ));

    return ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(mockApi),
        authProvider.overrideWith(() => AuthNotifier(
              secureStorage: MockSecureStorage(),
              apiService: mockApi,
              onDeepLink: (_) {},
              autoInitialize: false,
              initialUser: user,
            )),
      ],
      child: const MaterialApp(home: OnboardingContactsScreen()),
    );
  }

  testWidgets('shows initial prompt with Find your friends heading',
      (tester) async {
    await tester.pumpWidget(createOnboardingScreen());
    await tester.pumpAndSettle();

    expect(find.text('Find your friends'), findsOneWidget);
    expect(find.text('Upload & find friends'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
  });

  testWidgets('shows privacy explanation in prompt', (tester) async {
    await tester.pumpWidget(createOnboardingScreen());
    await tester.pumpAndSettle();

    // App Review (5.1.2) — explicit disclosure language. The prompt
    // splits the explanation across two paragraphs; assert on stable
    // substrings the test won't have to re-track on prose tweaks.
    // Build 40: copy was reworded from "one-way hashes" to
    // "anonymized codes" — same disclosure intent, layperson wording.
    expect(
      find.textContaining('anonymized codes'),
      findsWidgets,
    );
    expect(
      find.textContaining('Your raw contacts never leave your device'),
      findsOneWidget,
    );
  });

  testWidgets('shows upload and skip buttons', (tester) async {
    await tester.pumpWidget(createOnboardingScreen());
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Upload & find friends'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Skip for now'), findsOneWidget);
  });
}
