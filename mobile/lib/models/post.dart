import 'post_reaction.dart';

class PostMedia {
  final String id;
  final String postId;
  final int position;
  final String mediaUrl;
  final String mediaType;
  final int? width;
  final int? height;

  /// For videos: CDN URL of a first-frame JPEG extracted client-side
  /// at upload time and stored alongside the video in Spaces. Null for
  /// photos (the `mediaUrl` itself is the still) and for legacy videos
  /// uploaded before this field existed.
  ///
  /// Used by the iOS widget and anywhere else that needs a still for a
  /// video — avoids loading the full mp4 just to seek to frame 0.
  final String? thumbnailUrl;

  PostMedia({
    required this.id,
    required this.postId,
    required this.position,
    required this.mediaUrl,
    required this.mediaType,
    this.width,
    this.height,
    this.thumbnailUrl,
  });

  factory PostMedia.fromJson(Map<String, dynamic> json) {
    return PostMedia(
      id: json['id'] as String,
      postId: json['post_id'] as String,
      position: json['position'] as int,
      mediaUrl: json['media_url'] as String,
      mediaType: json['media_type'] as String,
      width: json['width'] as int?,
      height: json['height'] as int?,
      thumbnailUrl: json['thumbnail_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'post_id': postId,
      'position': position,
      'media_url': mediaUrl,
      'media_type': mediaType,
      'width': width,
      'height': height,
      'thumbnail_url': thumbnailUrl,
    };
  }
}

class PostComment {
  final String id;
  final String userId;
  final String body;
  final String displayName;
  final String? avatarUrl;
  final DateTime createdAt;

  PostComment({
    required this.id,
    required this.userId,
    required this.body,
    required this.displayName,
    this.avatarUrl,
    required this.createdAt,
  });

  factory PostComment.fromJson(Map<String, dynamic> json) {
    return PostComment(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      body: json['body'] as String,
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class Post {
  final String id;
  final String userId;
  final String? caption;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  final List<PostMedia> media;
  final String displayName;
  final String? avatarUrl;
  final int commentCount;
  final List<PostComment> recentComments;
  final int likeCount;
  final bool isLiked;
  final DateTime? expiresAt;

  /// Per-emoji reaction summary returned by the feed + post-detail
  /// enrichment. Empty when nobody has reacted yet (the strip widget
  /// renders no chips in that case — only the "+" affordance shows).
  final List<PostReaction> reactions;

  Post({
    required this.id,
    required this.userId,
    this.caption,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
    required this.media,
    required this.displayName,
    this.avatarUrl,
    this.commentCount = 0,
    this.recentComments = const [],
    this.likeCount = 0,
    this.isLiked = false,
    this.expiresAt,
    this.reactions = const [],
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      caption: json['caption'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      deletedAt: json['deleted_at'] != null
          ? DateTime.parse(json['deleted_at'] as String)
          : null,
      media: (json['media'] as List<dynamic>?)
              ?.map((e) => PostMedia.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      commentCount: json['comment_count'] as int? ?? 0,
      recentComments: (json['recent_comments'] as List<dynamic>?)
              ?.map((e) => PostComment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      likeCount: json['like_count'] as int? ?? 0,
      isLiked: json['is_liked'] as bool? ?? false,
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
      reactions: (json['reactions'] as List<dynamic>?)
              ?.map((e) => PostReaction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'caption': caption,
      'created_at': createdAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'media': media.map((e) => e.toJson()).toList(),
      'display_name': displayName,
      'avatar_url': avatarUrl,
      'comment_count': commentCount,
      'like_count': likeCount,
      'is_liked': isLiked,
      'expires_at': expiresAt?.toIso8601String(),
      'reactions': reactions.map((r) => r.toJson()).toList(),
    };
  }

  /// Returns a copy of this Post with the given fields replaced. Any
  /// argument left null defaults to the existing field — pass an
  /// explicit value (or empty list / `false` etc.) to override.
  ///
  /// Required because optimistic-update paths (feed_provider's
  /// toggleLike, post_detail's like override) used to manually
  /// rebuild a Post field-by-field, which silently dropped any new
  /// field added to the class. With copyWith, adding a field here +
  /// threading it through fromJson/toJson is enough — every optimistic
  /// path inherits the new field automatically.
  Post copyWith({
    String? id,
    String? userId,
    String? caption,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
    List<PostMedia>? media,
    String? displayName,
    String? avatarUrl,
    int? commentCount,
    List<PostComment>? recentComments,
    int? likeCount,
    bool? isLiked,
    DateTime? expiresAt,
    List<PostReaction>? reactions,
  }) {
    return Post(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      caption: caption ?? this.caption,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      media: media ?? this.media,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      commentCount: commentCount ?? this.commentCount,
      recentComments: recentComments ?? this.recentComments,
      likeCount: likeCount ?? this.likeCount,
      isLiked: isLiked ?? this.isLiked,
      expiresAt: expiresAt ?? this.expiresAt,
      reactions: reactions ?? this.reactions,
    );
  }
}
