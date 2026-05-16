class Comment {
  final String id;
  final String postId;
  final String userId;
  final String body;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  final String displayName;
  final String? avatarUrl;

  /// If this comment is a reply, the parent comment's id. Null for
  /// top-level comments. Source of truth for @-style reply rendering;
  /// the client doesn't parse `@{name}` out of the body text.
  final String? replyToCommentId;

  /// Author of the parent comment. Used to make the `@{name}` prefix
  /// tappable — navigates to their profile. Null when not a reply.
  final String? replyToUserId;

  /// Display name of the parent comment's author, populated server-side
  /// via LEFT JOIN in GET /posts/:id/comments. Null when not a reply.
  final String? replyToDisplayName;

  /// Total likes on this comment. 0 if nobody has liked it.
  final int likeCount;

  /// Whether the viewing user has liked this comment.
  final bool isLiked;

  Comment({
    required this.id,
    required this.postId,
    required this.userId,
    required this.body,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
    required this.displayName,
    this.avatarUrl,
    this.replyToCommentId,
    this.replyToUserId,
    this.replyToDisplayName,
    this.likeCount = 0,
    this.isLiked = false,
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
      id: json['id'] as String,
      postId: json['post_id'] as String,
      userId: json['user_id'] as String,
      body: json['body'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      deletedAt: json['deleted_at'] != null
          ? DateTime.parse(json['deleted_at'] as String)
          : null,
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      replyToCommentId: json['reply_to_comment_id'] as String?,
      replyToUserId: json['reply_to_user_id'] as String?,
      replyToDisplayName: json['reply_to_display_name'] as String?,
      likeCount: json['like_count'] as int? ?? 0,
      isLiked: json['is_liked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'post_id': postId,
      'user_id': userId,
      'body': body,
      'created_at': createdAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'display_name': displayName,
      'avatar_url': avatarUrl,
      'reply_to_comment_id': replyToCommentId,
      'reply_to_user_id': replyToUserId,
      'reply_to_display_name': replyToDisplayName,
      'like_count': likeCount,
      'is_liked': isLiked,
    };
  }

  /// Returns a copy with individual fields overridden. Used for
  /// optimistic toggles in the comments provider.
  Comment copyWith({
    int? likeCount,
    bool? isLiked,
  }) {
    return Comment(
      id: id,
      postId: postId,
      userId: userId,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
      displayName: displayName,
      avatarUrl: avatarUrl,
      replyToCommentId: replyToCommentId,
      replyToUserId: replyToUserId,
      replyToDisplayName: replyToDisplayName,
      likeCount: likeCount ?? this.likeCount,
      isLiked: isLiked ?? this.isLiked,
    );
  }
}
