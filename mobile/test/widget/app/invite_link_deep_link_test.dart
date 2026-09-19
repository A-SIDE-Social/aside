import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:aside/core/platform/deep_link.dart';
import 'package:aside/core/platform/invite_input.dart';
import 'package:aside/core/platform/pending_deep_link_listener.dart';

void main() {
  group('Production invite parser', () {
    const hosts = ['example.com', 'www.example.com'];
    for (final input in [
      'k7m2pq9xj4n6',
      ' K7M2PQ9XJ4N6 ',
      'https://example.com/k7m2pq9xj4n6',
      'www.example.com/K7M2PQ9XJ4N6/?utm=sms#invite',
      'aside://invite/k7m2pq9xj4n6',
    ]) {
      test('accepts $input', () {
        expect(
            InviteInput.parse(input, allowedHosts: hosts)?.code.toLowerCase(),
            'k7m2pq9xj4n6');
      });
    }
    for (final input in [
      'https://example.com/join/Ab12cd34ef56',
      'aside://join/Ab12cd34ef56',
    ]) {
      test('preserves legacy code in $input', () {
        final parsed = InviteInput.parse(input, allowedHosts: hosts)!;
        expect(parsed.code, 'Ab12cd34ef56');
        expect(parsed.route, '/u/Ab12cd34ef56?legacy=1');
      });
    }
    for (final input in [
      '',
      'short',
      'https://attacker.test/k7m2pq9xj4n6',
      'https://example.com/k7m2pq9xj4n6/extra',
      'https://example.com//k7m2pq9xj4n6',
      'https://user@example.com/k7m2pq9xj4n6',
      'ftp://example.com/k7m2pq9xj4n6',
      'aside://unknown/k7m2pq9xj4n6',
      'aside://invite/k7m2pq9xj4n6/extra',
      'https://example.com/about',
    ]) {
      test('rejects $input', () {
        expect(InviteInput.parse(input, allowedHosts: hosts), isNull);
      });
    }
  });

  for (final cold in [false, true]) {
    for (final signedIn in [false, true]) {
      testWidgets(
          '${cold ? 'cold' : 'warm'} link ${signedIn ? 'signed in' : 'survives login'}',
          (tester) async {
        final container = ProviderContainer();
        final ready = ValueNotifier(signedIn);
        final router = GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('Home'))),
          GoRoute(
              path: '/u/:slug',
              builder: (_, state) => Scaffold(
                  appBar: AppBar(),
                  body: Text('Invite ${state.pathParameters['slug']}'))),
        ]);
        addTearDown(container.dispose);
        addTearDown(ready.dispose);
        addTearDown(router.dispose);
        if (cold) {
          container
              .read(pendingDeepLinkProvider.notifier)
              .set('/u/k7m2pq9xj4n6');
        }
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: ValueListenableBuilder<bool>(
                valueListenable: ready,
                builder: (_, value, __) => PendingDeepLinkListener(
                    router: router,
                    authenticated: value,
                    child: MaterialApp.router(routerConfig: router)))));
        if (!cold) {
          container
              .read(pendingDeepLinkProvider.notifier)
              .set('/u/k7m2pq9xj4n6');
        }
        await tester.pumpAndSettle();
        if (!signedIn) {
          expect(find.text('Home'), findsOneWidget);
          expect(container.read(pendingDeepLinkProvider), '/u/k7m2pq9xj4n6');
          ready.value = true;
          await tester.pumpAndSettle();
        }
        expect(find.text('Invite k7m2pq9xj4n6'), findsOneWidget);
        expect(container.read(pendingDeepLinkProvider), isNull);
        expect(find.byType(BackButton), findsOneWidget);
        // Duplicate OS delivery must not stack the same confirmation twice.
        container.read(pendingDeepLinkProvider.notifier).set('/u/k7m2pq9xj4n6');
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
      });
    }
  }
}
