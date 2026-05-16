import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/comment.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('Comment', () {
    test('fromJson parses all required fields', () {
      final json = commentJson(
        id: 'c1',
        postId: 'p1',
        userId: 'u2',
        body: 'Nice!',
        displayName: 'Bob',
        createdAt: '2025-01-15T12:00:00.000Z',
      );
      final comment = Comment.fromJson(json);

      expect(comment.id, 'c1');
      expect(comment.postId, 'p1');
      expect(comment.userId, 'u2');
      expect(comment.body, 'Nice!');
      expect(comment.displayName, 'Bob');
      expect(comment.createdAt, DateTime.utc(2025, 1, 15, 12));
    });

    test('fromJson handles null updatedAt and deletedAt', () {
      final comment = Comment.fromJson(commentJson());
      expect(comment.updatedAt, isNull);
      expect(comment.deletedAt, isNull);
    });

    test('fromJson parses updatedAt and deletedAt when present', () {
      final json = commentJson(
        updatedAt: '2025-02-01T00:00:00.000Z',
        deletedAt: '2025-03-01T00:00:00.000Z',
      );
      final comment = Comment.fromJson(json);
      expect(comment.updatedAt, DateTime.utc(2025, 2, 1));
      expect(comment.deletedAt, DateTime.utc(2025, 3, 1));
    });

    test('fromJson handles null avatarUrl', () {
      final json = commentJson();
      json.remove('avatar_url');
      final comment = Comment.fromJson(json);
      expect(comment.avatarUrl, isNull);
    });

    test('toJson roundtrip preserves all fields', () {
      final original = commentJson(id: 'c1', body: 'Test comment');
      final comment = Comment.fromJson(original);
      final roundtripped = Comment.fromJson(comment.toJson());

      expect(roundtripped.id, comment.id);
      expect(roundtripped.body, comment.body);
      expect(roundtripped.displayName, comment.displayName);
    });

    test('fromJson defaults likeCount to 0 and isLiked to false', () {
      final json = commentJson();
      json.remove('like_count');
      json.remove('is_liked');
      final comment = Comment.fromJson(json);
      expect(comment.likeCount, 0);
      expect(comment.isLiked, false);
    });

    test('fromJson parses reply metadata', () {
      final comment = Comment.fromJson(commentJson(
        replyToCommentId: 'parent-1',
        replyToUserId: 'user-parent',
        replyToDisplayName: 'Alice',
      ));
      expect(comment.replyToCommentId, 'parent-1');
      expect(comment.replyToUserId, 'user-parent');
      expect(comment.replyToDisplayName, 'Alice');
    });

    test('replyToUserId is null for non-replies', () {
      final comment = Comment.fromJson(commentJson());
      expect(comment.replyToCommentId, isNull);
      expect(comment.replyToUserId, isNull);
      expect(comment.replyToDisplayName, isNull);
    });

    test('fromJson parses like state', () {
      final comment =
          Comment.fromJson(commentJson(likeCount: 7, isLiked: true));
      expect(comment.likeCount, 7);
      expect(comment.isLiked, true);
    });

    test('copyWith updates only specified fields', () {
      final comment =
          Comment.fromJson(commentJson(likeCount: 3, isLiked: false));
      final toggled = comment.copyWith(isLiked: true, likeCount: 4);
      expect(toggled.isLiked, true);
      expect(toggled.likeCount, 4);
      // Unchanged fields preserved
      expect(toggled.id, comment.id);
      expect(toggled.body, comment.body);
      expect(toggled.displayName, comment.displayName);
    });
  });
}
