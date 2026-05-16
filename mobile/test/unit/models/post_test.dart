import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/post.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('PostMedia', () {
    test('fromJson parses all fields', () {
      final json = postMediaJson(
        id: 'm1',
        postId: 'p1',
        position: 2,
        mediaUrl: 'https://example.com/photo.jpg',
        mediaType: 'photo',
        width: 1080,
        height: 1920,
      );
      final media = PostMedia.fromJson(json);

      expect(media.id, 'm1');
      expect(media.postId, 'p1');
      expect(media.position, 2);
      expect(media.mediaUrl, 'https://example.com/photo.jpg');
      expect(media.mediaType, 'photo');
      expect(media.width, 1080);
      expect(media.height, 1920);
    });

    test('fromJson handles null width and height', () {
      final json = postMediaJson();
      json.remove('width');
      json.remove('height');
      final media = PostMedia.fromJson(json);

      expect(media.width, isNull);
      expect(media.height, isNull);
    });

    test('toJson roundtrip preserves all fields', () {
      final media = PostMedia.fromJson(postMediaJson(width: 800, height: 600));
      final roundtripped = PostMedia.fromJson(media.toJson());

      expect(roundtripped.id, media.id);
      expect(roundtripped.width, 800);
      expect(roundtripped.height, 600);
    });

    test('fromJson parses video media type', () {
      final json = postMediaJson(
        mediaType: 'video',
        mediaUrl: 'https://example.com/clip.mp4',
      );
      final media = PostMedia.fromJson(json);

      expect(media.mediaType, 'video');
      expect(media.mediaUrl, 'https://example.com/clip.mp4');
    });

    test('fromJson parses thumbnailUrl for video media', () {
      final json = postMediaJson(
        mediaType: 'video',
        mediaUrl: 'https://example.com/clip.mp4',
        thumbnailUrl: 'https://example.com/clip-thumb.jpg',
      );
      final media = PostMedia.fromJson(json);

      expect(media.thumbnailUrl, 'https://example.com/clip-thumb.jpg');
    });

    test('fromJson thumbnailUrl is null when absent (photo / legacy video)',
        () {
      final photo = PostMedia.fromJson(postMediaJson(mediaType: 'photo'));
      expect(photo.thumbnailUrl, isNull);

      final legacyVideo = PostMedia.fromJson(
        postMediaJson(mediaType: 'video'),
      );
      expect(legacyVideo.thumbnailUrl, isNull);
    });

    test('toJson roundtrip preserves thumbnailUrl', () {
      final media = PostMedia.fromJson(
        postMediaJson(
          mediaType: 'video',
          thumbnailUrl: 'https://example.com/t.jpg',
        ),
      );
      final roundtripped = PostMedia.fromJson(media.toJson());

      expect(roundtripped.thumbnailUrl, 'https://example.com/t.jpg');
    });
  });

  group('PostComment', () {
    test('fromJson parses all fields including DateTime', () {
      final json = postCommentJson(
        id: 'pc1',
        body: 'Great!',
        createdAt: '2025-03-15T08:00:00.000Z',
      );
      final comment = PostComment.fromJson(json);

      expect(comment.id, 'pc1');
      expect(comment.body, 'Great!');
      expect(comment.createdAt, DateTime.utc(2025, 3, 15, 8));
    });

    test('fromJson handles null avatarUrl', () {
      final json = postCommentJson();
      json.remove('avatar_url');
      final comment = PostComment.fromJson(json);
      expect(comment.avatarUrl, isNull);
    });
  });

  group('Post', () {
    test('fromJson parses all fields including nested media list', () {
      final json = postJson(
        id: 'p1',
        caption: 'My post',
        media: [postMediaJson(id: 'm1'), postMediaJson(id: 'm2')],
        commentCount: 5,
        recentComments: [postCommentJson(id: 'pc1')],
      );
      final post = Post.fromJson(json);

      expect(post.id, 'p1');
      expect(post.caption, 'My post');
      expect(post.media.length, 2);
      expect(post.media[0].id, 'm1');
      expect(post.media[1].id, 'm2');
      expect(post.commentCount, 5);
      expect(post.recentComments.length, 1);
      expect(post.recentComments[0].id, 'pc1');
    });

    test('fromJson handles null media list', () {
      final json = postJson();
      json.remove('media');
      final post = Post.fromJson(json);
      expect(post.media, isEmpty);
    });

    test('fromJson handles null recentComments', () {
      final json = postJson();
      json.remove('recent_comments');
      final post = Post.fromJson(json);
      expect(post.recentComments, isEmpty);
    });

    test('fromJson defaults commentCount to 0 when missing', () {
      final json = postJson();
      json.remove('comment_count');
      final post = Post.fromJson(json);
      expect(post.commentCount, 0);
    });

    test('fromJson parses nullable updatedAt and deletedAt', () {
      final json = postJson(
        updatedAt: '2025-02-01T00:00:00.000Z',
        deletedAt: '2025-03-01T00:00:00.000Z',
      );
      final post = Post.fromJson(json);

      expect(post.updatedAt, DateTime.utc(2025, 2, 1));
      expect(post.deletedAt, DateTime.utc(2025, 3, 1));
    });

    test('fromJson handles null updatedAt and deletedAt', () {
      final json = postJson();
      final post = Post.fromJson(json);
      expect(post.updatedAt, isNull);
      expect(post.deletedAt, isNull);
    });

    test('toJson produces correct structure', () {
      final post = Post.fromJson(postJson(caption: 'Test'));
      final json = post.toJson();

      expect(json['caption'], 'Test');
      expect(json['media'], isList);
      expect(json.containsKey('user_id'), isTrue);
    });

    test('fromJson parses post with video media', () {
      final json = postJson(
        caption: 'Video post',
        media: [
          postMediaJson(
              id: 'v1',
              mediaType: 'video',
              mediaUrl: 'https://example.com/clip.mp4'),
        ],
      );
      final post = Post.fromJson(json);

      expect(post.media.length, 1);
      expect(post.media[0].mediaType, 'video');
    });

    test('fromJson parses post with mixed photo and video media', () {
      final json = postJson(
        media: [
          postMediaJson(id: 'm1', mediaType: 'photo', position: 0),
          postMediaJson(id: 'm2', mediaType: 'video', position: 1),
          postMediaJson(id: 'm3', mediaType: 'photo', position: 2),
        ],
      );
      final post = Post.fromJson(json);

      expect(post.media.length, 3);
      expect(post.media[0].mediaType, 'photo');
      expect(post.media[1].mediaType, 'video');
      expect(post.media[2].mediaType, 'photo');
    });

    group('like fields', () {
      test('fromJson parses likeCount and isLiked', () {
        final json = postJson(likeCount: 42, isLiked: true);
        final post = Post.fromJson(json);

        expect(post.likeCount, 42);
        expect(post.isLiked, isTrue);
      });

      test('fromJson defaults likeCount to 0 when missing', () {
        final json = postJson();
        json.remove('like_count');
        final post = Post.fromJson(json);
        expect(post.likeCount, 0);
      });

      test('fromJson defaults isLiked to false when missing', () {
        final json = postJson();
        json.remove('is_liked');
        final post = Post.fromJson(json);
        expect(post.isLiked, isFalse);
      });

      test('toJson includes like fields', () {
        final post = Post.fromJson(postJson(likeCount: 10, isLiked: true));
        final json = post.toJson();

        expect(json['like_count'], 10);
        expect(json['is_liked'], isTrue);
      });

      test('toJson roundtrip preserves like fields', () {
        final post = Post.fromJson(postJson(likeCount: 7, isLiked: true));
        final roundtripped = Post.fromJson(post.toJson());

        expect(roundtripped.likeCount, 7);
        expect(roundtripped.isLiked, isTrue);
      });

      test('unliked post has likeCount 0 and isLiked false', () {
        final post = Post.fromJson(postJson(likeCount: 0, isLiked: false));

        expect(post.likeCount, 0);
        expect(post.isLiked, isFalse);
      });
    });

    group('expiresAt field', () {
      test('fromJson parses expiresAt when present', () {
        final json = postJson(expiresAt: '2025-06-01T12:00:00.000Z');
        final post = Post.fromJson(json);

        expect(post.expiresAt, DateTime.utc(2025, 6, 1, 12));
      });

      test('fromJson defaults expiresAt to null when missing', () {
        final json = postJson();
        json.remove('expires_at');
        final post = Post.fromJson(json);
        expect(post.expiresAt, isNull);
      });

      test('fromJson handles null expiresAt', () {
        final json = postJson(expiresAt: null);
        final post = Post.fromJson(json);
        expect(post.expiresAt, isNull);
      });

      test('toJson includes expires_at', () {
        final json = postJson(expiresAt: '2025-06-01T12:00:00.000Z');
        final post = Post.fromJson(json);
        final output = post.toJson();

        expect(output['expires_at'], isNotNull);
      });

      test('toJson roundtrip preserves expiresAt', () {
        final json = postJson(expiresAt: '2025-06-01T12:00:00.000Z');
        final post = Post.fromJson(json);
        final roundtripped = Post.fromJson(post.toJson());

        expect(roundtripped.expiresAt, post.expiresAt);
      });
    });
  });
}
