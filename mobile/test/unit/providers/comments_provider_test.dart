import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/comments_provider.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/mocks.dart';

// Pumps a ProviderContainer through microtasks until the provider's
// AsyncValue settles out of `loading`. Works for Notifier-backed
// AsyncValue without needing the `.future` getter that FutureProviders
// expose.
Future<AsyncValue<List<dynamic>>> _untilSettled(
  ProviderContainer container,
  ProviderListenable<AsyncValue<List<dynamic>>> provider,
) async {
  // Pump microtasks a few times — the constructor fires _load() which
  // awaits the API, then sets state. Two pumps is typically enough.
  for (var i = 0; i < 10; i++) {
    final value = container.read(provider);
    if (value is! AsyncLoading) return value;
    await Future<void>.delayed(Duration.zero);
  }
  return container.read(provider);
}

void main() {
  group('commentsProvider', () {
    late MockApiService mockApi;

    setUp(() {
      mockApi = MockApiService();
    });

    test('fetches and parses comments for a post ID', () async {
      when(() => mockApi.getComments('post-1')).thenAnswer(
        (_) async => [commentJson(id: 'c1'), commentJson(id: 'c2')],
      );

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      // Subscribe so the notifier instantiates + starts loading.
      container.listen(commentsProvider('post-1'), (_, __) {});
      final settled =
          await _untilSettled(container, commentsProvider('post-1'));
      final comments = settled.value!;
      expect(comments.length, 2);
      expect(comments[0].id, 'c1');
      expect(comments[1].id, 'c2');
    });

    test('returns empty list when API returns empty array', () async {
      when(() => mockApi.getComments('post-2')).thenAnswer((_) async => []);

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      container.listen(commentsProvider('post-2'), (_, __) {});
      final settled =
          await _untilSettled(container, commentsProvider('post-2'));
      expect(settled.value, isEmpty);
    });

    test('propagates error when API call fails', () async {
      // .thenAnswer with an async throw produces a rejected Future on
      // each call. .thenThrow yields a sync throw which the notifier's
      // try/catch in _load handles synchronously, before the listener
      // sees the error transition — settles to data(empty) instead.
      when(() => mockApi.getComments('post-3'))
          .thenAnswer((_) async => throw Exception('Network error'));

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      container.listen(commentsProvider('post-3'), (_, __) {});
      final settled =
          await _untilSettled(container, commentsProvider('post-3'));
      expect(settled.hasError, true);
    });

    test('toggleLike optimistically flips isLiked and increments count',
        () async {
      when(() => mockApi.getComments('post-4')).thenAnswer(
        (_) async => [commentJson(id: 'c1', likeCount: 2, isLiked: false)],
      );
      when(() => mockApi.likeComment('c1'))
          .thenAnswer((_) async => {'liked': true, 'like_count': 3});

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      container.listen(commentsProvider('post-4'), (_, __) {});
      await _untilSettled(container, commentsProvider('post-4'));

      final notifier = container.read(commentsProvider('post-4').notifier);
      // Fire-and-peek: optimistic flip happens synchronously before the
      // await on api.likeComment resolves.
      final future = notifier.toggleLike('c1');
      final midFlight = container.read(commentsProvider('post-4')).value!;
      expect(midFlight.first.isLiked, true);
      expect(midFlight.first.likeCount, 3);
      await future;

      verify(() => mockApi.likeComment('c1')).called(1);
    });

    test('toggleLike reverts on API failure', () async {
      when(() => mockApi.getComments('post-5')).thenAnswer(
        (_) async => [commentJson(id: 'c1', likeCount: 0, isLiked: false)],
      );
      when(() => mockApi.likeComment('c1')).thenThrow(Exception('boom'));

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      container.listen(commentsProvider('post-5'), (_, __) {});
      await _untilSettled(container, commentsProvider('post-5'));

      await container
          .read(commentsProvider('post-5').notifier)
          .toggleLike('c1');

      final settled = container.read(commentsProvider('post-5')).value!;
      expect(settled.first.isLiked, false);
      expect(settled.first.likeCount, 0);
    });

    test('toggleLike on already-liked calls unlikeComment and decrements',
        () async {
      when(() => mockApi.getComments('post-6')).thenAnswer(
        (_) async => [commentJson(id: 'c1', likeCount: 5, isLiked: true)],
      );
      when(() => mockApi.unlikeComment('c1'))
          .thenAnswer((_) async => {'liked': false, 'like_count': 4});

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      container.listen(commentsProvider('post-6'), (_, __) {});
      await _untilSettled(container, commentsProvider('post-6'));

      await container
          .read(commentsProvider('post-6').notifier)
          .toggleLike('c1');

      final settled = container.read(commentsProvider('post-6')).value!;
      expect(settled.first.isLiked, false);
      expect(settled.first.likeCount, 4);
      verify(() => mockApi.unlikeComment('c1')).called(1);
    });
  });
}
