import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/models/post.dart';
import 'package:aside/providers/feed_provider.dart';
import 'package:aside/providers/api_provider.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;
  late ProviderContainer container;

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

  group('FeedNotifier', () {
    group('incrementCommentCount', () {
      test('increments comment count for matching post', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1', commentCount: 3),
                postJson(id: 'p2', commentCount: 0),
              ]
            });

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        // Wait for initial load
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        notifier.incrementCommentCount('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].commentCount, 4);
        expect(posts[1].commentCount, 0);
      });

      test('preserves like fields when incrementing comment count', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(
                    id: 'p1', commentCount: 0, likeCount: 5, isLiked: true),
              ]
            });

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        notifier.incrementCommentCount('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].commentCount, 1);
        expect(posts[0].likeCount, 5);
        expect(posts[0].isLiked, isTrue);
      });
    });

    group('toggleLike', () {
      test('optimistically likes an unliked post', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1', likeCount: 0, isLiked: false),
              ]
            });
        when(() => mockApi.likePost('p1')).thenAnswer((_) async => {});

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        // Start toggle (don't await — check optimistic state)
        final future = notifier.toggleLike('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].isLiked, isTrue);
        expect(posts[0].likeCount, 1);

        await future;
      });

      test('optimistically unlikes a liked post', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1', likeCount: 3, isLiked: true),
              ]
            });
        when(() => mockApi.unlikePost('p1')).thenAnswer((_) async => {});

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        final future = notifier.toggleLike('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].isLiked, isFalse);
        expect(posts[0].likeCount, 2);

        await future;
      });

      test('reverts on API failure', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1', likeCount: 5, isLiked: false),
              ]
            });
        when(() => mockApi.likePost('p1'))
            .thenThrow(Exception('Network error'));

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        await notifier.toggleLike('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].isLiked, isFalse);
        expect(posts[0].likeCount, 5);
      });

      test('does not affect other posts in the feed', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1', likeCount: 0, isLiked: false),
                postJson(id: 'p2', likeCount: 10, isLiked: true),
              ]
            });
        when(() => mockApi.likePost('p1')).thenAnswer((_) async => {});

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        await notifier.toggleLike('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].isLiked, isTrue);
        expect(posts[0].likeCount, 1);
        // p2 unchanged
        expect(posts[1].isLiked, isTrue);
        expect(posts[1].likeCount, 10);
      });

      test('likeCount does not go below zero', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1', likeCount: 0, isLiked: true),
              ]
            });
        when(() => mockApi.unlikePost('p1')).thenAnswer((_) async => {});

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        await notifier.toggleLike('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts[0].likeCount, 0);
        expect(posts[0].isLiked, isFalse);
      });
    });

    group('cursor pagination', () {
      // Build 25 regression: the cursor used to be `posts.last.id` (a UUID),
      // which the backend then bound to a `$2::timestamptz` parameter and
      // surfaced as a 500 `DateTimeParseError`. The cursor is now the last
      // post's `created_at` formatted as ISO-8601 in UTC.
      test(
          'loadInitial sets _nextCursor to the last post createdAt as ISO string',
          () async {
        // Need at least 20 posts so the notifier sets _hasMore=true and
        // loadMore actually reaches the API call we want to inspect.
        final fullPage = List.generate(20, (i) {
          // Times decreasing so the last entry has the earliest timestamp.
          final ts =
              '2026-04-14T${(20 - i).toString().padLeft(2, '0')}:00:00.000Z';
          return postJson(id: 'p$i', createdAt: ts);
        });
        // Last post has timestamp '2026-04-14T01:00:00.000Z' — that's what
        // the cursor should turn into.
        const expectedCursor = '2026-04-14T01:00:00.000Z';

        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {'posts': fullPage});

        container = createContainer();
        container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        // Override with a more specific stub for the loadMore call so we
        // can stop the recursion (return empty next page).
        when(() => mockApi.getFeed(
              before: expectedCursor,
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {'posts': []});

        await container.read(feedNotifierProvider.notifier).loadMore();

        // Verify loadMore was called with the ISO timestamp of the last
        // post, NOT its UUID. If the bug regresses the captured value
        // would be 'p19' or similar.
        final captured = verify(() => mockApi.getFeed(
              before: captureAny(named: 'before'),
              groupId: any(named: 'groupId'),
            )).captured;
        // Two calls: loadInitial (before: null), loadMore (before: cursor).
        final loadMoreBefore = captured.last as String?;
        expect(loadMoreBefore, isNotNull);
        expect(loadMoreBefore, equals(expectedCursor));
        // Sanity-check it's a parseable timestamp — exactly what the
        // server validates with parseBeforeCursor.
        expect(() => DateTime.parse(loadMoreBefore!), returnsNormally);
        // And explicitly NOT a UUID (the regression we're guarding against).
        expect(loadMoreBefore, isNot(matches(RegExp(r'^[0-9a-f-]{36}$'))));
      });

      test('loadInitial sets cursor to null when the feed is empty', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {'posts': []});

        container = createContainer();
        final notifier = container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        // hasMore should be false on an empty initial load (length < 20).
        expect(notifier.hasMore, isFalse);
      });
    });

    group('removePost', () {
      test('removes matching post from state', () async {
        when(() => mockApi.getFeed(
              before: any(named: 'before'),
              groupId: any(named: 'groupId'),
            )).thenAnswer((_) async => {
              'posts': [
                postJson(id: 'p1'),
                postJson(id: 'p2'),
              ]
            });

        container = createContainer();
        container.read(feedNotifierProvider.notifier);

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        container.read(feedNotifierProvider.notifier).removePost('p1');

        final posts = container.read(feedNotifierProvider).value!;
        expect(posts.length, 1);
        expect(posts[0].id, 'p2');
      });
    });
  });

  // Pure selection logic used by FeedNotifier._cacheWidgetImage to
  // decide which post (and which URL within that post) gets cached
  // for the iOS widget. Kept factored out + exported so we can
  // verify the carousel / video-thumbnail rules without spinning up
  // the auth + app-group native bridge plumbing.
  group('pickWidgetImage', () {
    Post buildPost({
      required String id,
      required String userId,
      required String displayName,
      required List<Map<String, dynamic>> mediaJsons,
    }) {
      return Post.fromJson(postJson(
        id: id,
        userId: userId,
        displayName: displayName,
        media: mediaJsons,
      ));
    }

    test('picks first photo in a photo-only post', () {
      final posts = [
        buildPost(
          id: 'p1',
          userId: 'friend',
          displayName: 'Maya',
          mediaJsons: [
            postMediaJson(id: 'a', mediaType: 'photo', mediaUrl: 'A.jpg'),
            postMediaJson(id: 'b', mediaType: 'photo', mediaUrl: 'B.jpg'),
          ],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      expect(pick?.imageUrl, 'A.jpg');
      expect(pick?.posterName, 'Maya');
    });

    test(
        'picks the first photo (not media[0]) when the carousel leads with a video',
        () {
      final posts = [
        buildPost(
          id: 'p1',
          userId: 'friend',
          displayName: 'Julien',
          mediaJsons: [
            postMediaJson(
              id: 'v',
              mediaType: 'video',
              mediaUrl: 'clip.mp4',
              thumbnailUrl: 'clip-thumb.jpg',
            ),
            postMediaJson(id: 'a', mediaType: 'photo', mediaUrl: 'A.jpg'),
            postMediaJson(id: 'b', mediaType: 'photo', mediaUrl: 'B.jpg'),
          ],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      // The exact bug the fix addresses: previously this returned null
      // (or skipped the post entirely) because the picker demanded
      // media[0] be a photo.
      expect(pick?.imageUrl, 'A.jpg');
      expect(pick?.posterName, 'Julien');
    });

    test('falls back to video thumbnail when no photo is present', () {
      final posts = [
        buildPost(
          id: 'p1',
          userId: 'friend',
          displayName: 'Sam',
          mediaJsons: [
            postMediaJson(
              id: 'v',
              mediaType: 'video',
              mediaUrl: 'clip.mp4',
              thumbnailUrl: 'clip-thumb.jpg',
            ),
          ],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      expect(pick?.imageUrl, 'clip-thumb.jpg');
      expect(pick?.posterName, 'Sam');
    });

    test('skips video-only posts that have no thumbnail (legacy uploads)', () {
      final posts = [
        // Legacy video post without thumbnail_url — server-rendered
        // before migration 016 landed. Picker should walk past it.
        buildPost(
          id: 'p1',
          userId: 'friend',
          displayName: 'Legacy',
          mediaJsons: [
            postMediaJson(
              id: 'v',
              mediaType: 'video',
              mediaUrl: 'clip.mp4',
              // thumbnailUrl intentionally omitted
            ),
          ],
        ),
        buildPost(
          id: 'p2',
          userId: 'friend',
          displayName: 'Maya',
          mediaJsons: [
            postMediaJson(id: 'a', mediaType: 'photo', mediaUrl: 'A.jpg'),
          ],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      expect(pick?.imageUrl, 'A.jpg');
      expect(pick?.posterName, 'Maya');
    });

    test('skips the current user\'s own posts', () {
      final posts = [
        buildPost(
          id: 'p1',
          userId: 'me', // own post
          displayName: 'Me',
          mediaJsons: [
            postMediaJson(id: 'a', mediaType: 'photo', mediaUrl: 'own.jpg'),
          ],
        ),
        buildPost(
          id: 'p2',
          userId: 'friend',
          displayName: 'Friend',
          mediaJsons: [
            postMediaJson(id: 'b', mediaType: 'photo', mediaUrl: 'friend.jpg'),
          ],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      expect(pick?.imageUrl, 'friend.jpg');
      expect(pick?.posterName, 'Friend');
    });

    test('skips text-only posts', () {
      final posts = [
        buildPost(
          id: 'p1',
          userId: 'friend',
          displayName: 'Texty',
          mediaJsons: [],
        ),
        buildPost(
          id: 'p2',
          userId: 'friend',
          displayName: 'Maya',
          mediaJsons: [
            postMediaJson(id: 'a', mediaType: 'photo', mediaUrl: 'A.jpg'),
          ],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      expect(pick?.imageUrl, 'A.jpg');
    });

    test('returns null when no eligible post exists', () {
      final posts = [
        buildPost(
          id: 'p1',
          userId: 'me',
          displayName: 'Me',
          mediaJsons: [
            postMediaJson(id: 'a', mediaType: 'photo', mediaUrl: 'A.jpg'),
          ],
        ),
        buildPost(
          id: 'p2',
          userId: 'friend',
          displayName: 'Texty',
          mediaJsons: [],
        ),
      ];
      final pick = pickWidgetImage(posts, currentUserId: 'me');
      expect(pick, isNull);
    });
  });
}
