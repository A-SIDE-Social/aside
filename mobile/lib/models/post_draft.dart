import 'dart:convert';

import '../core/media/media_transform.dart';

/// A locally-persisted draft of an in-progress post.
///
/// Created when an upload stalls and the user chooses "Save as Draft".
/// Stores caption text, local file paths still pending upload, and any media
/// entries that were already uploaded (so resume skips those).
class PostDraft {
  final String id;
  final String caption;
  final bool isTextPost;

  /// Absolute file paths on disk for every picked item (both already uploaded
  /// and still pending). Parallel to [videoFlags].
  final List<String> localFilePaths;

  /// `true` for items at the same index in [localFilePaths] that were picked
  /// as videos (separate from photos on pick). Parallel array.
  final List<bool> videoFlags;

  /// Media entries the server already has. Each entry is the same shape sent
  /// to `POST /posts` (key, media_type, position, width, height). Indices
  /// 0..completedMedia.length-1 in [localFilePaths] are already uploaded;
  /// resume starts at `nextFileIndex`.
  final List<Map<String, dynamic>> completedMedia;

  final int nextFileIndex;
  final DateTime createdAt;

  /// Per-image filter selections, keyed by media index.
  /// e.g. {0: 'warm_fade', 2: 'hard_mono'} means image 0 has Warm Fade,
  /// image 2 has Hard Mono, and all others have no filter.
  final Map<int, String> filterIds;

  /// Per-image crop+straighten transforms, keyed by media index.
  /// Absent entries are treated as identity (no transform). Stored
  /// alongside [filterIds] since they apply to the same indices.
  final Map<int, MediaTransform> transforms;

  const PostDraft({
    required this.id,
    required this.caption,
    required this.isTextPost,
    required this.localFilePaths,
    required this.videoFlags,
    required this.completedMedia,
    required this.nextFileIndex,
    required this.createdAt,
    this.filterIds = const {},
    this.transforms = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'caption': caption,
        'is_text_post': isTextPost,
        'local_file_paths': localFilePaths,
        'video_flags': videoFlags,
        'completed_media': completedMedia,
        'next_file_index': nextFileIndex,
        'created_at': createdAt.toIso8601String(),
        if (filterIds.isNotEmpty)
          'filter_ids': filterIds.map((k, v) => MapEntry(k.toString(), v)),
        if (transforms.isNotEmpty)
          'transforms':
              transforms.map((k, v) => MapEntry(k.toString(), v.toJson())),
      };

  factory PostDraft.fromJson(Map<String, dynamic> json) => PostDraft(
        id: json['id'] as String,
        caption: (json['caption'] as String?) ?? '',
        isTextPost: (json['is_text_post'] as bool?) ?? false,
        localFilePaths: (json['local_file_paths'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
        videoFlags: (json['video_flags'] as List<dynamic>? ?? [])
            .map((e) => e as bool)
            .toList(),
        completedMedia: (json['completed_media'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        nextFileIndex: (json['next_file_index'] as int?) ?? 0,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
        filterIds: (json['filter_ids'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(int.parse(k), v as String)) ??
            // Backwards compat: old single filterId → apply to index 0
            (json['filter_id'] != null ? {0: json['filter_id'] as String} : {}),
        transforms: (json['transforms'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(
                int.parse(k),
                MediaTransform.fromJson(v as Map<String, dynamic>),
              ),
            ) ??
            const {},
      );

  String encode() => jsonEncode(toJson());
  static PostDraft decode(String raw) =>
      PostDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
