import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/features/settings/edit_profile_name_screen.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;
  late ProviderContainer container;

  setUp(() {
    mockApi = MockApiService();
    final user = User.fromJson(
      userJson(id: 'me-1', displayName: 'Old Name'),
    );
    container = ProviderContainer(
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
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: EditProfileNameScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('starts with the current profile name', (tester) async {
    await pumpScreen(tester);

    final field = tester.widget<TextFormField>(
      find.byKey(const Key('profile-name-field')),
    );
    expect(field.controller?.text, 'Old Name');
  });

  testWidgets('requires a non-empty name', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('save-profile-name')));
    await tester.pump();

    expect(find.text('Enter your name'), findsOneWidget);
    verifyNever(() => mockApi.updateMe(displayName: any(named: 'displayName')));
  });

  testWidgets('saves a trimmed name and updates auth state', (tester) async {
    when(() => mockApi.updateMe(displayName: 'New Name')).thenAnswer(
      (_) async => userJson(id: 'me-1', displayName: 'New Name'),
    );
    await pumpScreen(tester);

    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      '  New Name  ',
    );
    await tester.tap(find.byKey(const Key('save-profile-name')));
    await tester.pumpAndSettle();

    verify(() => mockApi.updateMe(displayName: 'New Name')).called(1);
    expect(container.read(authProvider).user?.displayName, 'New Name');
    expect(find.text('Name updated'), findsOneWidget);
  });
}
