import 'package:flutter_test/flutter_test.dart';
import 'package:aside/core/media/media_transform.dart';
import 'package:aside/models/post_draft.dart';

void main() {
  PostDraft makeDraft({
    Map<int, String>? filterIds,
    Map<int, MediaTransform>? transforms,
  }) =>
      PostDraft(
        id: 'test-id',
        caption: 'Test caption',
        isTextPost: false,
        localFilePaths: ['/a.jpg', '/b.jpg', '/c.jpg'],
        videoFlags: [false, false, false],
        completedMedia: [],
        nextFileIndex: 0,
        createdAt: DateTime(2025, 1, 1),
        filterIds: filterIds ?? {},
        transforms: transforms ?? {},
      );

  group('PostDraft per-image filter persistence', () {
    test('empty filterIds round-trips correctly', () {
      final draft = makeDraft();
      final json = draft.toJson();
      expect(json.containsKey('filter_ids'), false);

      final restored = PostDraft.fromJson(json);
      expect(restored.filterIds, isEmpty);
    });

    test('filterIds round-trips correctly', () {
      final draft = makeDraft(filterIds: {0: 'portra', 2: 'trix'});
      final json = draft.toJson();
      expect(json['filter_ids'], {'0': 'portra', '2': 'trix'});

      final restored = PostDraft.fromJson(json);
      expect(restored.filterIds, {0: 'portra', 2: 'trix'});
    });

    test('encode/decode preserves filterIds', () {
      final draft = makeDraft(filterIds: {1: 'hp5'});
      final encoded = draft.encode();
      final decoded = PostDraft.decode(encoded);
      expect(decoded.filterIds, {1: 'hp5'});
    });

    test('backwards compat: old filter_id migrates to filterIds', () {
      final oldJson = {
        'id': 'old-draft',
        'caption': 'Old post',
        'is_text_post': false,
        'local_file_paths': ['/a.jpg'],
        'video_flags': [false],
        'completed_media': <Map<String, dynamic>>[],
        'next_file_index': 0,
        'created_at': '2025-01-01T00:00:00.000',
        'filter_id': 'portra',
      };
      final restored = PostDraft.fromJson(oldJson);
      expect(restored.filterIds, {0: 'portra'});
    });

    test('backwards compat: no filter_id or filter_ids yields empty map', () {
      final oldJson = {
        'id': 'old-draft',
        'caption': '',
        'local_file_paths': <String>[],
        'video_flags': <bool>[],
        'completed_media': <Map<String, dynamic>>[],
        'created_at': '2025-01-01T00:00:00.000',
      };
      final restored = PostDraft.fromJson(oldJson);
      expect(restored.filterIds, isEmpty);
    });

    test('new filter_ids takes precedence over old filter_id', () {
      final json = {
        'id': 'test',
        'caption': '',
        'local_file_paths': ['/a.jpg', '/b.jpg'],
        'video_flags': [false, false],
        'completed_media': <Map<String, dynamic>>[],
        'created_at': '2025-01-01T00:00:00.000',
        'filter_id': 'portra',
        'filter_ids': {'0': 'trix', '1': 'hp5'},
      };
      final restored = PostDraft.fromJson(json);
      expect(restored.filterIds, {0: 'trix', 1: 'hp5'});
    });
  });

  group('PostDraft per-image transform persistence', () {
    test('empty transforms serialize without the key', () {
      final draft = makeDraft();
      final json = draft.toJson();
      expect(json.containsKey('transforms'), false);

      final restored = PostDraft.fromJson(json);
      expect(restored.transforms, isEmpty);
    });

    test('non-empty transforms round-trip through toJson/fromJson', () {
      final draft = makeDraft(transforms: {
        0: MediaTransform(rotation: 0.1, scale: 1.5),
        2: MediaTransform(
          rotation: -0.05,
          scale: 2.0,
          offset: const Offset(10, -3),
        ),
      });
      final json = draft.toJson();
      expect(json.containsKey('transforms'), true);

      final restored = PostDraft.fromJson(json);
      expect(restored.transforms.keys.toSet(), {0, 2});
      expect(restored.transforms[0]!.rotation, 0.1);
      expect(restored.transforms[0]!.scale, 1.5);
      expect(restored.transforms[2]!.rotation, -0.05);
      expect(restored.transforms[2]!.offset, const Offset(10, -3));
    });

    test('encode/decode preserves transforms', () {
      final draft = makeDraft(transforms: {
        1: MediaTransform(rotation: 0.12, scale: 1.3),
      });
      final decoded = PostDraft.decode(draft.encode());
      expect(decoded.transforms.length, 1);
      expect(decoded.transforms[1]!.rotation, 0.12);
      expect(decoded.transforms[1]!.scale, 1.3);
    });

    test('backwards compat: drafts without transforms load as empty', () {
      final oldJson = {
        'id': 'd',
        'caption': '',
        'local_file_paths': ['/a.jpg'],
        'video_flags': [false],
        'completed_media': <Map<String, dynamic>>[],
        'created_at': '2025-01-01T00:00:00.000',
      };
      final restored = PostDraft.fromJson(oldJson);
      expect(restored.transforms, isEmpty);
    });

    test('filters and transforms coexist independently', () {
      final draft = makeDraft(
        filterIds: {0: 'hard_mono'},
        transforms: {1: MediaTransform(rotation: 0.1)},
      );
      final back = PostDraft.decode(draft.encode());
      expect(back.filterIds, {0: 'hard_mono'});
      expect(back.transforms.keys, [1]);
    });
  });
}
