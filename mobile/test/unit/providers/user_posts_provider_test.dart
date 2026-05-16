import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/user_posts_provider.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/mocks.dart';

void main() {
  group('userPostsProvider', () {
    late MockApiService mockApi;

    setUp(() {
      mockApi = MockApiService();
    });

    test('fetches and parses posts for a user ID', () async {
      when(() => mockApi.getUserPosts('u1')).thenAnswer(
        (_) async => [postJson(id: 'p1'), postJson(id: 'p2')],
      );

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      final posts = await container.read(userPostsProvider('u1').future);
      expect(posts.length, 2);
      expect(posts[0].id, 'p1');
    });

    test('returns empty list when API returns empty array', () async {
      when(() => mockApi.getUserPosts('u2')).thenAnswer((_) async => []);

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      final posts = await container.read(userPostsProvider('u2').future);
      expect(posts, isEmpty);
    });

    test('propagates error when API call fails', () async {
      when(() => mockApi.getUserPosts('u3'))
          .thenAnswer((_) async => throw Exception('Network error'));

      final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);

      // Subscribe first so the provider actually builds and the future
      // can settle before tearDown disposes the container. Without an
      // active listener Riverpod 3 may keep the provider in `loading`
      // until disposal, swallowing the underlying error in a StateError.
      final sub = container.listen(userPostsProvider('u3'), (_, __) {});
      addTearDown(sub.close);

      // Pump microtasks until the AsyncValue settles.
      var snapshot = container.read(userPostsProvider('u3'));
      for (var i = 0; i < 20 && snapshot is AsyncLoading; i++) {
        await Future<void>.delayed(Duration.zero);
        snapshot = container.read(userPostsProvider('u3'));
      }
      expect(snapshot.hasError, isTrue);
      expect(snapshot.error, isA<Exception>());
    });
  });
}
