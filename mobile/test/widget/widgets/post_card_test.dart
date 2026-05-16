import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/post.dart';
import '../../helpers/fixtures.dart';

void main() {
  // PostCard requires network images and video_player initialization,
  // so we test the model-level behavior that drives rendering decisions.

  group('PostMedia type detection', () {
    test('photo media type is correctly identified', () {
      final media = PostMedia.fromJson(postMediaJson(mediaType: 'photo'));
      expect(media.mediaType, 'photo');
      expect(media.mediaType != 'video', isTrue);
    });

    test('video media type is correctly identified', () {
      final media = PostMedia.fromJson(postMediaJson(mediaType: 'video'));
      expect(media.mediaType, 'video');
    });

    test('mixed media post has correct types at each position', () {
      final post = Post.fromJson(postJson(
        media: [
          postMediaJson(id: 'm1', mediaType: 'photo', position: 0),
          postMediaJson(id: 'm2', mediaType: 'video', position: 1),
        ],
      ));

      expect(post.media[0].mediaType, 'photo');
      expect(post.media[1].mediaType, 'video');
    });
  });

  group('Post media counts', () {
    test('single video post has one media item', () {
      final post = Post.fromJson(postJson(
        media: [
          postMediaJson(id: 'v1', mediaType: 'video'),
        ],
      ));
      expect(post.media.length, 1);
    });

    test('post with max media items parses correctly', () {
      final mediaList = List.generate(
        10,
        (i) => postMediaJson(
          id: 'media-$i',
          mediaType: i % 3 == 0 ? 'video' : 'photo',
          position: i,
        ),
      );
      final post = Post.fromJson(postJson(media: mediaList));
      expect(post.media.length, 10);

      // Verify video items at indices 0, 3, 6, 9
      expect(post.media[0].mediaType, 'video');
      expect(post.media[1].mediaType, 'photo');
      expect(post.media[3].mediaType, 'video');
      expect(post.media[6].mediaType, 'video');
      expect(post.media[9].mediaType, 'video');
    });
  });

  group('Text-only post', () {
    test('text post has empty media list', () {
      final post = Post.fromJson(postJson(
        caption: 'Just text',
        media: [],
      ));
      expect(post.media, isEmpty);
      expect(post.caption, 'Just text');
    });
  });

  group('Post like state for PostCard rendering', () {
    test('liked post has isLiked true and positive likeCount', () {
      final post = Post.fromJson(postJson(
        likeCount: 5,
        isLiked: true,
      ));

      expect(post.isLiked, isTrue);
      expect(post.likeCount, 5);
    });

    test('unliked post has isLiked false', () {
      final post = Post.fromJson(postJson(
        likeCount: 3,
        isLiked: false,
      ));

      expect(post.isLiked, isFalse);
      expect(post.likeCount, 3);
    });

    test('post with zero likes shows correct state', () {
      final post = Post.fromJson(postJson(
        likeCount: 0,
        isLiked: false,
      ));

      expect(post.isLiked, isFalse);
      expect(post.likeCount, 0);
    });

    test('like state is independent of comment count', () {
      final post = Post.fromJson(postJson(
        commentCount: 10,
        likeCount: 7,
        isLiked: true,
      ));

      expect(post.commentCount, 10);
      expect(post.likeCount, 7);
      expect(post.isLiked, isTrue);
    });
  });
}
