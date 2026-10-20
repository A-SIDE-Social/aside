import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/providers/api_provider.dart';
import 'package:aside/features/feed/feed_screen.dart';
import 'package:aside/models/post.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/providers/feed_updates_provider.dart';
import 'package:aside/providers/feed_provider.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        status: AuthStatus.authenticated,
        user: User.fromJson(userJson(id: 'feed-reader')),
      );
}

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
        authProvider.overrideWith(_Auth.new),
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
    testWidgets('failed pagination keeps posts and retries only after a tap',
        (tester) async {
      var pageCalls = 0;
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((invocation) async {
        if (invocation.namedArguments[#before] == null) {
          return {
            'posts': List.generate(
                20, (i) => postJson(id: 'p$i', caption: 'Post $i', media: []))
          };
        }
        if (++pageCalls == 1) throw Exception('Offline');
        return {
          'posts': [postJson(id: 'next', caption: 'Next page', media: [])]
        };
      });
      stubGroupsEmpty();
      await tester.pumpWidget(createFeedScreen());
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(FeedScreen))).pop();
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(FeedScreen)));
      await container.read(feedNotifierProvider.notifier).loadMore();
      await tester.pumpAndSettle();
      expect(container.read(feedNotifierProvider.notifier).pageFailed, isTrue);
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      for (var i = 0;
          i < 20 && find.text('Retry loading posts').evaluate().isEmpty;
          i++) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(find.text('Retry loading posts'), findsOneWidget);
      expect(pageCalls, 1);
      expect(container.read(feedNotifierProvider).value, hasLength(20));
      await tester.tap(find.text('Retry loading posts'));
      await tester.pumpAndSettle();
      expect(pageCalls, 2);
      expect(container.read(feedNotifierProvider).value!.last.id, 'next');
      expect(find.text('Retry loading posts'), findsNothing);
    });

    testWidgets('new posts wait for a tap and clear after a successful refresh',
        (tester) async {
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => {'posts': <dynamic>[]});
      stubGroupsEmpty();
      await tester.pumpWidget(createFeedScreen());
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(FeedScreen))).pop();
      await tester.pumpAndSettle();
      verify(() => mockApi.getFeed(before: null, groupId: null)).called(1);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FeedScreen)),
      );
      container.read(feedUpdatesProvider.notifier).receive('friend-post');
      await tester.pump();
      expect(find.byKey(const ValueKey('new-posts-button')), findsOneWidget);
      verifyNever(() => mockApi.getFeed(before: null, groupId: null));
      await tester.tap(find.byKey(const ValueKey('new-posts-button')));
      await tester.pumpAndSettle();
      verify(() => mockApi.getFeed(before: null, groupId: null)).called(1);
      expect(find.byKey(const ValueKey('new-posts-button')), findsNothing);
    });

    testWidgets('refresh acknowledges posts received since opening Home',
        (tester) async {
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => {'posts': []});
      stubGroupsEmpty();

      await tester.pumpWidget(createFeedScreen());
      await tester.pumpAndSettle();
      verify(() => mockApi.markFeedSeen()).called(1);

      final indicator = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await indicator.onRefresh();
      await tester.pumpAndSettle();

      verify(() => mockApi.markFeedSeen()).called(1);
      expect(tester.takeException(), isNull);
    });

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
