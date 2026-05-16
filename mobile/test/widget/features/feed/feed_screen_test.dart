import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/providers/api_provider.dart';
import 'package:aside/features/feed/feed_screen.dart';
import 'package:aside/models/post.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createFeedScreen({
    AsyncValue<List<Post>>? feedState,
  }) {
    return ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(mockApi),
      ],
      child: const MaterialApp(
        home: Scaffold(body: FeedScreen()),
      ),
    );
  }

  void stubGroupsEmpty() {
    when(() => mockApi.getLists()).thenAnswer((_) async => []);
    // FeedScreen.initState fires `markFeedSeen` on the first frame so
    // the in-app new-post badge clears. Stub it to a no-op Future so
    // mocktail doesn't return null for a Future<void> return type.
    when(() => mockApi.markFeedSeen()).thenAnswer((_) async {});
  }

  group('FeedScreen', () {
    testWidgets('shows empty state when feed has no posts', (tester) async {
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => {'posts': []});
      stubGroupsEmpty();

      await tester.pumpWidget(createFeedScreen());
      await tester.pumpAndSettle();

      expect(find.text('No posts yet'), findsOneWidget);
    });

    testWidgets('shows posts when feed has data', (tester) async {
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => {
            'posts': [
              postJson(id: 'p1', caption: 'Hello world', displayName: 'Alice'),
            ]
          });
      stubGroupsEmpty();

      await tester.pumpWidget(createFeedScreen());
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsWidgets);
    });
  });
}
