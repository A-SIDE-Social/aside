import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/features/post/post_detail_screen.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createScreen() {
    final user = User.fromJson(userJson(
      id: 'me-1',
      displayName: 'My Name',
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
      child: const MaterialApp(
        home: PostDetailScreen(postId: 'p1'),
      ),
    );
  }

  group('PostDetailScreen reactions', () {
    testWidgets('tapping an existing reaction sends one toggle request',
        (tester) async {
      when(() => mockApi.getPost('p1')).thenAnswer(
        (_) async => postJson(
          id: 'p1',
          userId: 'friend-1',
          caption: 'Lunch',
          media: [],
          reactions: [
            {'emoji': '🔥', 'count': 1, 'reacted_by_me': true},
          ],
        ),
      );
      when(() => mockApi.getComments('p1')).thenAnswer((_) async => []);
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => {'posts': []});
      when(() => mockApi.togglePostReaction('p1', '🔥'))
          .thenAnswer((_) async => []);

      await tester.pumpWidget(createScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('🔥'));
      await tester.pumpAndSettle();

      verify(() => mockApi.togglePostReaction('p1', '🔥')).called(1);
    });
  });
}
