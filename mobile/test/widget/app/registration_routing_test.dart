import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/app.dart';
import 'package:aside/core/platform/deep_link.dart';
import 'package:aside/core/platform/pending_deep_link_listener.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/models/user.dart';
import '../../helpers/mocks.dart';
import '../../helpers/fixtures.dart';

class _Auth extends AuthNotifier {
  @override
  AuthState build() => const AuthState(status: AuthStatus.unauthenticated);
  void register() => state = AuthState(
      status: AuthStatus.authenticated,
      isNewRegistration: true,
      user: User.fromJson(userJson(id: 'new-user')));
}

void main() {
  for (final hasInvite in [false, true]) {
    testWidgets(
        'production registration redirect ${hasInvite ? 'retains invite' : 'offers manual entry without contacts'}',
        (tester) async {
      final api = MockApiService();
      when(() => api.getUserBySlug('k7m2pq9xj4n6')).thenAnswer(
          (_) async => {'id': 'friend', 'display_name': 'My friend'});
      final auth = _Auth();
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(() => auth),
        apiServiceProvider.overrideWithValue(api),
      ]);
      final router = container.read(routerProvider);
      addTearDown(router.dispose);
      addTearDown(container.dispose);
      if (hasInvite) {
        container.read(pendingDeepLinkProvider.notifier).set('/u/k7m2pq9xj4n6');
      }
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: Consumer(
              builder: (_, ref, __) => PendingDeepLinkListener(
                  router: router,
                  authenticated: ref.watch(authProvider).status ==
                      AuthStatus.authenticated,
                  child: MaterialApp.router(routerConfig: router)))));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/sign-in');
      auth.register();
      await tester.pumpAndSettle();
      if (hasInvite) {
        expect(router.state.uri.path, '/u/k7m2pq9xj4n6');
        expect(find.text('My friend'), findsOneWidget);
        verifyNever(() => api.requestFromSlug(any()));
      } else {
        expect(router.state.uri.path, '/onboarding/contacts');
        await tester.ensureVisible(find.text('Use an invite link or code'));
        await tester.tap(find.text('Use an invite link or code'));
        await tester.pumpAndSettle();
        expect(find.text('Invite link or code'), findsOneWidget);
        verifyNever(() => api.syncContacts(any()));
      }
    });
  }
}
