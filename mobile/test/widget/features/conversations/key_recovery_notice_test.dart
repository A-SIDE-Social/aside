import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/crypto/key_registry_sync.dart';
import 'package:aside/features/conversations/conversations_screen.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import '../../../helpers/mocks.dart';
import '../../../helpers/fixtures.dart';

class _Sync extends Mock implements KeyRegistrySync {}

void main() {
  for (final conflict in [true, false]) {
    testWidgets(
        'key recovery is visible and retries without resetting ($conflict)',
        (tester) async {
      final api = MockApiService();
      final sync = _Sync();
      final storage = MockSecureStorage();
      when(() => api.getConversations()).thenAnswer((_) async => []);
      var attempts = 0;
      when(() => sync.ensureKeysInitialized(
          ownerUserId: any(named: 'ownerUserId'))).thenAnswer((_) async {
        if (++attempts == 1) {
          if (conflict) {
            throw const KeyRecoveryRequired('Different active identity');
          }
          throw DioException(
              requestOptions: RequestOptions(path: '/fixture'),
              type: DioExceptionType.connectionError);
        }
        return false;
      });
      final container = ProviderContainer(overrides: [
        apiServiceProvider.overrideWithValue(api),
        authProvider.overrideWith(() => AuthNotifier(
              secureStorage: storage,
              apiService: api,
              keyRegistrySync: sync,
              autoInitialize: false,
              initialUser: User.fromJson(userJson(id: 'owner')),
            )),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationsScreen())));
      await container.read(authProvider.notifier).retryKeyRegistration();
      await tester.pumpAndSettle();
      expect(find.textContaining('Your keys have been kept'), findsOneWidget);
      expect(container.read(authProvider).status, AuthStatus.authenticated);
      expect(
          container.read(authProvider).keyRegistrationStatus,
          conflict
              ? KeyRegistrationStatus.recoveryRequired
              : KeyRegistrationStatus.unavailable);
      await tester.tap(find.text('Retry setup'));
      await tester.pumpAndSettle();
      expect(container.read(authProvider).keyRegistrationStatus,
          KeyRegistrationStatus.ready);
      expect(find.text('Retry setup'), findsNothing);
      expect(attempts, 2);
      verifyNever(() => sync.resetKeys());
      verifyNever(() => storage.clearAll());
    });
  }
}
