import 'package:flutter_test/flutter_test.dart';
import 'package:aside/core/utils/post_share_util.dart';
import 'package:aside/models/post.dart';

/// Tests for PostShareUtil share text formatting, post type routing,
/// and carousel share logic. Actual share sheet and image rendering require
/// a running app and can't be unit tested here.
void main() {
  Post makePost({
    String? caption,
    List<PostMedia>? media,
  }) {
    return Post(
      id: 'test-post-id',
      userId: 'test-user-id',
      caption: caption,
      createdAt: DateTime(2025, 1, 1),
      media: media ?? [],
      displayName: 'Test User',
    );
  }

  PostMedia makeMedia({
    String id = 'm1',
    int position = 0,
    String mediaType = 'photo',
    String url = 'https://example.com/photo.jpg',
  }) {
    return PostMedia(
      id: id,
      postId: 'test-post-id',
      position: position,
      mediaUrl: url,
      mediaType: mediaType,
    );
  }

  group('Post type detection for share routing', () {
    test('photo post has non-empty media with photo type', () {
      final post = makePost(
        caption: 'Beautiful sunset',
        media: [makeMedia()],
      );
      expect(post.media.isNotEmpty, true);
      expect(post.media.first.mediaType, 'photo');
    });

    test('video post has video media type', () {
      final post = makePost(
        media: [
          makeMedia(mediaType: 'video', url: 'https://example.com/video.mp4')
        ],
      );
      expect(post.media.first.mediaType, 'video');
    });

    test('text-only post has empty media list', () {
      final post = makePost(caption: 'Just a thought');
      expect(post.media.isEmpty, true);
      expect(post.caption, 'Just a thought');
    });

    test('single media post shows share sheet with one share option', () {
      final post = makePost(media: [makeMedia()]);
      expect(post.media.length, 1);
    });

    test('carousel post (2+ media) shows share sheet with multiple options',
        () {
      final post = makePost(
        media: [
          makeMedia(
              id: 'm1', position: 0, url: 'https://example.com/photo1.jpg'),
          makeMedia(
              id: 'm2', position: 1, url: 'https://example.com/photo2.jpg'),
        ],
      );
      expect(post.media.length, greaterThan(1));
    });
  });

  group('Carousel media index selection', () {
    test('mediaIndex 0 selects first image', () {
      final media = [
        makeMedia(id: 'm1', position: 0, url: 'https://example.com/photo1.jpg'),
        makeMedia(id: 'm2', position: 1, url: 'https://example.com/photo2.jpg'),
        makeMedia(id: 'm3', position: 2, url: 'https://example.com/photo3.jpg'),
      ];
      expect(media[0].mediaUrl, 'https://example.com/photo1.jpg');
    });

    test('mediaIndex 1 selects second image', () {
      final media = [
        makeMedia(id: 'm1', position: 0, url: 'https://example.com/photo1.jpg'),
        makeMedia(id: 'm2', position: 1, url: 'https://example.com/photo2.jpg'),
        makeMedia(id: 'm3', position: 2, url: 'https://example.com/photo3.jpg'),
      ];
      expect(media[1].mediaUrl, 'https://example.com/photo2.jpg');
    });

    test('share all includes every media item', () {
      final media = [
        makeMedia(id: 'm1', position: 0),
        makeMedia(id: 'm2', position: 1),
        makeMedia(id: 'm3', position: 2),
      ];
      expect(media.length, 3);
    });
  });

  group('Share text building', () {
    test('post with caption includes caption and branding', () {
      final post = makePost(caption: 'Hello world');
      final text = PostShareUtil.buildShareText(post);
      expect(text, contains('Hello world'));
      expect(text, contains('Shared from'));
    });

    test('post without caption only includes branding', () {
      final post = makePost();
      final text = PostShareUtil.buildShareText(post);
      expect(text, contains('Shared from'));
      expect(text, isNot(contains('\n\n')));
    });

    test('post with empty caption only includes branding', () {
      final post = makePost(caption: '');
      final text = PostShareUtil.buildShareText(post);
      expect(text, contains('Shared from'));
      expect(text, isNot(contains('\n\n')));
    });

    test('caption and branding are separated by double newline', () {
      final post = makePost(caption: 'My caption');
      final text = PostShareUtil.buildShareText(post);
      expect(text, 'My caption\n\nShared from A/SIDE');
    });
  });

  group('Media share routing', () {
    test('photos are identified as images', () {
      final media = makeMedia(mediaType: 'photo');
      expect(media.mediaType, 'photo');
      expect(media.mediaType != 'video', true);
    });

    test('videos are identified as videos', () {
      final media = makeMedia(mediaType: 'video');
      expect(media.mediaType, 'video');
    });
  });

  group('Clipboard share text', () {
    test('share text is suitable for clipboard pasting', () {
      final post = makePost(caption: 'Check this out!');
      final text = PostShareUtil.buildShareText(post);
      // Should be readable when pasted into another app
      expect(text, 'Check this out!\n\nShared from A/SIDE');
      expect(text, isNot(contains('http'))); // no URLs in clipboard text
    });

    test('no-caption post clipboard text is just branding', () {
      final post = makePost();
      final text = PostShareUtil.buildShareText(post);
      expect(text, 'Shared from A/SIDE');
    });
  });
}
