import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/core/crypto/key_registry_sync.dart';
import 'package:aside/features/conversations/messaging_recovery_screen.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/auth_provider.dart';
import '../../../helpers/mocks.dart';
import '../../../helpers/fixtures.dart';

class _Sync extends Mock implements KeyRegistrySync {}

void main() {
  for (final confirm in [false, true]) {
    testWidgets(
        'device change requires warning and email confirmation ($confirm)',
        (tester) async {
      final sync = _Sync();
      when(() => sync.requestMessagingRecovery(ownerUserId: 'owner'))
          .thenAnswer((_) async {});
      when(() => sync.confirmMessagingRecovery(
          ownerUserId: 'owner', code: '123456')).thenAnswer((_) async {});
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(() => AuthNotifier(
            secureStorage: MockSecureStorage(),
            apiService: MockApiService(),
            keyRegistrySync: sync,
            autoInitialize: false,
            initialUser: User.fromJson(userJson(id: 'owner')))),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (_) =>
                                      const MessagingRecoveryScreen())),
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('does not transfer message history'),
          findsOneWidget);
      verifyNever(() => sync.requestMessagingRecovery(ownerUserId: 'owner'));
      if (!confirm) {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => sync.requestMessagingRecovery(ownerUserId: 'owner'));
      } else {
        await tester.tap(find.text('Email me a code'));
        await tester.pumpAndSettle();
        verify(() => sync.requestMessagingRecovery(ownerUserId: 'owner'))
            .called(1);
        verifyNever(() => sync.confirmMessagingRecovery(
            ownerUserId: 'owner', code: '123456'));
        final button = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirm device change'));
        expect(button.onPressed, isNull);
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        await tester.tap(find.text('Confirm device change'));
        await tester.pumpAndSettle();
        verify(() => sync.confirmMessagingRecovery(
            ownerUserId: 'owner', code: '123456')).called(1);
        expect(container.read(authProvider).keyRegistrationStatus,
            KeyRegistrationStatus.ready);
      }
      verifyNever(() => sync.resetKeys());
    });
  }
}
