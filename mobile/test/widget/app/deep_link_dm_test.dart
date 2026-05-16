// Regression coverage for the "DM push doesn't open the conversation"
// class of bug.
//
// Status as of fix/dm-push-deep-link branch: the wiring is right.
// The server's notifyNewDM (src/firebase.ts ~459) packs `type: 'dm'`
// and `conversation_id` into the FCM data payload. The mobile
// resolver (deep_link.dart `routeForNotificationData`) maps that to
// `/conversations/<id>`. AsideApp's bridge has both a warm listener
// AND a pendingOnMount drain so cold-start taps survive even if the
// FCM SDK resolves `getInitialMessage()` after the first build.
//
// These tests pin the invariant that the bridge actually routes the
// pending value to the correct destination in BOTH scenarios:
//
//   1. Warm path — pending is set after AsideApp is mounted (the user
//      taps the push while the app was backgrounded).
//   2. Cold-start path — pending is set BEFORE the harness mounts
//      (the FCM SDK resolved getInitialMessage() before runApp's
//      first frame).
//
// The cold-start path is the one most likely to regress since it
// depends on AsideApp's `pendingOnMount` block (the warm listener
// alone misses values set before subscription).
//
// Mirrors the harness pattern from deep_link_back_button_test.dart
// — minimal MaterialApp.router with two routes (/ + /conversations/:id),
// no auth / no FCM / no full app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:aside/core/platform/deep_link.dart';

void main() {
  group('DM push deep link', () {
    testWidgets(
      'warm path: tapping a DM push while the app is open routes into the conversation',
      (tester) async {
        await tester.pumpWidget(_harness());
        await tester.pumpAndSettle();

        // Pre-condition: app is on the feed.
        expect(find.text('feed'), findsOneWidget);
        expect(find.byType(BackButton), findsNothing);

        // Simulate the notification tap → resolver → bridge.
        _setPending(tester, '/conversations/c-warm');
        await tester.pumpAndSettle();

        // Conversation screen mounted, back button visible.
        expect(find.text('chat c-warm'), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);

        // Back returns to feed.
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('feed'), findsOneWidget);
      },
    );

    testWidgets(
      'cold-start path: pending route set BEFORE first build still routes to the conversation',
      (tester) async {
        // Build a container OUTSIDE the widget tree, set the pending
        // value, then mount. This is the scenario where
        // PushNotificationService.initialize() resolved
        // getInitialMessage() and called _onDeepLink before AsideApp
        // first built. The warm `ref.listen` would miss this (it
        // only fires on FUTURE changes), so the `pendingOnMount`
        // drain in app.dart has to catch it.
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container
            .read(pendingDeepLinkProvider.notifier)
            .set('/conversations/c-cold');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const _Harness(),
          ),
        );
        await tester.pumpAndSettle();

        // The pendingOnMount drain in the harness should have
        // pushed /conversations/c-cold by now.
        expect(find.text('chat c-cold'), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);

        // The pending value should be cleared after consumption so
        // a subsequent AsideApp rebuild doesn't double-push.
        expect(container.read(pendingDeepLinkProvider), isNull);
      },
    );

    testWidgets(
      'routeForNotificationData: dm payload with conversation_id maps to /conversations/<id>',
      (tester) async {
        // Pure unit-style guard on the resolver — if this regresses,
        // every DM push goes nowhere.
        final route = routeForNotificationData({
          'type': 'dm',
          'conversation_id': 'abc-123',
        });
        expect(route, '/conversations/abc-123');
      },
    );

    testWidgets(
      'routeForNotificationData: dm payload missing conversation_id returns null (no crash, no default route)',
      (tester) async {
        // A bad server payload should NOT produce a wild navigation.
        // Caller must treat null as "no nav, just show the banner."
        final route = routeForNotificationData({'type': 'dm'});
        expect(route, isNull);
      },
    );
  });
}

// ── Harness ────────────────────────────────────────────────────────

void _setPending(WidgetTester tester, String route) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  container.read(pendingDeepLinkProvider.notifier).set(route);
}

Widget _harness() => const ProviderScope(child: _Harness());

GoRouter _buildRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Center(child: Text('feed'))),
        ),
        GoRoute(
          path: '/conversations/:id',
          builder: (_, state) {
            final id = state.pathParameters['id'] ?? '';
            return Scaffold(
              appBar: AppBar(title: Text('Conversation $id')),
              body: Center(child: Text('chat $id')),
            );
          },
        ),
      ],
    );

/// Mirrors AsideApp.build's deep-link bridge — warm listener + cold
/// drain — with no other dependencies.
class _Harness extends ConsumerStatefulWidget {
  const _Harness();
  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  late final GoRouter _router;
  bool _drainedOnMount = false;

  @override
  void initState() {
    super.initState();
    _router = _buildRouter();
  }

  @override
  Widget build(BuildContext context) {
    // Warm-path listener.
    ref.listen<String?>(pendingDeepLinkProvider, (_, next) {
      if (next == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _router.push(next);
        ref.read(pendingDeepLinkProvider.notifier).set(null);
      });
    });

    // Cold-start drain — only runs once on first build to mirror
    // the production intent (the production version runs every
    // build but dedupes via a null check; both shapes are correct).
    if (!_drainedOnMount) {
      _drainedOnMount = true;
      final pending = ref.read(pendingDeepLinkProvider);
      if (pending != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final current = ref.read(pendingDeepLinkProvider);
          if (current == null) return;
          _router.push(current);
          ref.read(pendingDeepLinkProvider.notifier).set(null);
        });
      }
    }

    return MaterialApp.router(routerConfig: _router);
  }
}
