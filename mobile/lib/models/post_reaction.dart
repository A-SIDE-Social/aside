/// One emoji's worth of reaction summary on a post — the emoji
/// itself, how many users picked it, and whether the current viewer
/// is one of them. Server returns these grouped per emoji per post
/// (see src/routes/feed.ts and src/routes/posts.ts enrichment).
class PostReaction {
  final String emoji;
  final int count;
  final bool reactedByMe;

  const PostReaction({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
  });

  factory PostReaction.fromJson(Map<String, dynamic> json) {
    return PostReaction(
      emoji: json['emoji'] as String,
      count: (json['count'] as num).toInt(),
      reactedByMe: json['reacted_by_me'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'emoji': emoji,
        'count': count,
        'reacted_by_me': reactedByMe,
      };

  PostReaction copyWith({
    String? emoji,
    int? count,
    bool? reactedByMe,
  }) {
    return PostReaction(
      emoji: emoji ?? this.emoji,
      count: count ?? this.count,
      reactedByMe: reactedByMe ?? this.reactedByMe,
    );
  }
}
