class Story {
  final String id;
  final String userId;
  final String mediaUrl;
  final String mediaType;
  final DateTime expiresAt;
  final DateTime createdAt;
  final String displayName;
  final String? avatarUrl;

  Story({
    required this.id,
    required this.userId,
    required this.mediaUrl,
    required this.mediaType,
    required this.expiresAt,
    required this.createdAt,
    required this.displayName,
    this.avatarUrl,
  });

  factory Story.fromJson(Map<String, dynamic> json) {
    return Story(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      mediaUrl: json['media_url'] as String,
      mediaType: json['media_type'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'media_url': mediaUrl,
      'media_type': mediaType,
      'expires_at': expiresAt.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'display_name': displayName,
      'avatar_url': avatarUrl,
    };
  }
}

class StoryGroup {
  final String userId;
  final String displayName;
  final String? avatarUrl;
  final List<Story> stories;

  StoryGroup({
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    required this.stories,
  });

  factory StoryGroup.fromJson(Map<String, dynamic> json) {
    // Backend returns nested { user: { id, display_name, ... }, stories: [...] }
    final user = json['user'] as Map<String, dynamic>?;
    return StoryGroup(
      userId: (user?['id'] ?? json['user_id']) as String,
      displayName: (user?['display_name'] ?? json['display_name']) as String,
      avatarUrl: (user?['avatar_url'] ?? json['avatar_url']) as String?,
      stories: (json['stories'] as List<dynamic>)
          .map((e) => Story.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'display_name': displayName,
      'avatar_url': avatarUrl,
      'stories': stories.map((e) => e.toJson()).toList(),
    };
  }
}
