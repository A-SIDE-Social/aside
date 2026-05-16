import 'package:flutter_test/flutter_test.dart';

import 'package:aside/models/story.dart';
import '../../helpers/fixtures.dart';

void main() {
  group('Story', () {
    test('fromJson parses all fields', () {
      final json = storyJson(
        id: 's1',
        userId: 'u1',
        mediaUrl: 'https://example.com/story.jpg',
        mediaType: 'photo',
        expiresAt: '2025-01-02T00:00:00.000Z',
        createdAt: '2025-01-01T12:00:00.000Z',
        displayName: 'Alice',
        avatarUrl: 'https://example.com/alice.jpg',
      );
      final story = Story.fromJson(json);

      expect(story.id, 's1');
      expect(story.userId, 'u1');
      expect(story.mediaUrl, 'https://example.com/story.jpg');
      expect(story.mediaType, 'photo');
      expect(story.expiresAt, DateTime.utc(2025, 1, 2));
      expect(story.createdAt, DateTime.utc(2025, 1, 1, 12));
      expect(story.displayName, 'Alice');
      expect(story.avatarUrl, 'https://example.com/alice.jpg');
    });

    test('fromJson handles null avatarUrl', () {
      final story = Story.fromJson(storyJson());
      expect(story.avatarUrl, isNull);
    });

    test('toJson roundtrip preserves all fields', () {
      final story = Story.fromJson(storyJson(id: 's2', mediaType: 'video'));
      final roundtripped = Story.fromJson(story.toJson());

      expect(roundtripped.id, story.id);
      expect(roundtripped.mediaType, 'video');
      expect(roundtripped.displayName, story.displayName);
    });
  });

  group('StoryGroup', () {
    test('fromJson parses nested user object format', () {
      final json = storyGroupJson(
        userId: 'u1',
        displayName: 'Alice',
        avatarUrl: 'https://example.com/alice.jpg',
        nested: true,
      );
      final group = StoryGroup.fromJson(json);

      expect(group.userId, 'u1');
      expect(group.displayName, 'Alice');
      expect(group.avatarUrl, 'https://example.com/alice.jpg');
      expect(group.stories.length, 1);
    });

    test('fromJson parses flat format', () {
      final json = storyGroupJson(
        userId: 'u2',
        displayName: 'Bob',
        nested: false,
      );
      final group = StoryGroup.fromJson(json);

      expect(group.userId, 'u2');
      expect(group.displayName, 'Bob');
    });

    test('fromJson parses stories list', () {
      final json = storyGroupJson(
        stories: [storyJson(id: 's1'), storyJson(id: 's2')],
      );
      final group = StoryGroup.fromJson(json);

      expect(group.stories.length, 2);
      expect(group.stories[0].id, 's1');
      expect(group.stories[1].id, 's2');
    });

    test('toJson produces correct structure', () {
      final group = StoryGroup.fromJson(storyGroupJson(userId: 'u1'));
      final json = group.toJson();

      expect(json['user_id'], 'u1');
      expect(json['stories'], isList);
    });
  });
}
