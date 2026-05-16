// InviteLinkNotifier unit tests.
//
// The notifier is an AsyncNotifier wrapping two API calls:
//   - build() reads GET /v1/invite-link
//   - regenerate() calls POST /v1/invite-link/regenerate
//
// We verify both ends: build() resolves to the parsed model, and
// regenerate() flips the state through loading → data and surfaces
// errors through the AsyncValue.error channel rather than throwing
// silently.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/invite_link_provider.dart';
import '../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  ProviderContainer createContainer() {
    final c = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(mockApi),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('InviteLink model', () {
    test('fromJson parses slug + url', () {
      final link = InviteLink.fromJson({
        'slug': 'k7m2pq9xj4n6',
        'url': 'https://example.com/k7m2pq9xj4n6',
      });
      expect(link.slug, 'k7m2pq9xj4n6');
      expect(link.url, 'https://example.com/k7m2pq9xj4n6');
    });
  });

  group('InviteLinkNotifier.build', () {
    test('resolves to InviteLink from /v1/invite-link payload', () async {
      when(() => mockApi.getInviteLink()).thenAnswer((_) async => {
            'slug': 'k7m2pq9xj4n6',
            'url': 'https://example.com/k7m2pq9xj4n6',
          });

      final container = createContainer();
      final value = await container.read(inviteLinkProvider.future);
      expect(value.slug, 'k7m2pq9xj4n6');
      expect(value.url, 'https://example.com/k7m2pq9xj4n6');
      verify(() => mockApi.getInviteLink()).called(1);
    });

    test('surfaces network failures as AsyncError', () async {
      // Use Future.error directly so the mock returns an already-
      // rejected Future (the shape Dio produces on network failure).
      // `thenAnswer((_) async => throw ...)` confuses mocktail's
      // type machinery here — the throw escapes synchronously
      // instead of surfacing inside the awaited future.
      when(() => mockApi.getInviteLink())
          .thenAnswer((_) => Future.error(Exception('boom')));
      final container = createContainer();
      // Read once to kick off build(), then settle the microtask
      // queue until the AsyncNotifier transitions loading → error.
      container.read(inviteLinkProvider);
      var settles = 0;
      while (container.read(inviteLinkProvider).isLoading && settles < 100) {
        await Future<void>.delayed(Duration.zero);
        settles += 1;
      }
      final state = container.read(inviteLinkProvider);
      expect(state.hasError, isTrue);
    });
  });

  group('InviteLinkNotifier.regenerate', () {
    test('updates state with the rotated slug + url', () async {
      when(() => mockApi.getInviteLink()).thenAnswer((_) async => {
            'slug': 'oldslug11111',
            'url': 'https://example.com/oldslug11111',
          });
      when(() => mockApi.regenerateInviteLink()).thenAnswer((_) async => {
            'slug': 'newslug22222',
            'url': 'https://example.com/newslug22222',
          });

      final container = createContainer();
      // Resolve initial build first
      final initial = await container.read(inviteLinkProvider.future);
      expect(initial.slug, 'oldslug11111');

      final result =
          await container.read(inviteLinkProvider.notifier).regenerate();

      expect(result.slug, 'newslug22222');
      final state = container.read(inviteLinkProvider).value;
      expect(state?.slug, 'newslug22222');
      verify(() => mockApi.regenerateInviteLink()).called(1);
    });

    test('rethrows server errors AND records them on state', () async {
      when(() => mockApi.getInviteLink()).thenAnswer((_) async => {
            'slug': 'oldslug11111',
            'url': 'https://example.com/oldslug11111',
          });
      when(() => mockApi.regenerateInviteLink())
          .thenAnswer((_) => Future.error(Exception('rate limited')));

      final container = createContainer();
      await container.read(inviteLinkProvider.future);

      // regenerate() rethrows, so we capture rather than expectLater
      // (which can race on the disposal of internal Riverpod state
      // when the notifier crashes mid-call).
      Object? caught;
      try {
        await container.read(inviteLinkProvider.notifier).regenerate();
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      // Mirrors the screen's UX — after a failed regenerate the
      // state shows the error so the UI can surface it rather than
      // silently revert.
      final state = container.read(inviteLinkProvider);
      expect(state.hasError, isTrue);
    });
  });
}
