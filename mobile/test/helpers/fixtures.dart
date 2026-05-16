// JSON factories and model builders for all models.
// Sensible defaults with optional overrides for each field.

import 'package:aside/models/models.dart';

// ── JSON factories ──────────────────────────────────────────

Map<String, dynamic> userJson({
  String? id,
  String? displayName,
  String? avatarUrl,
  String? bio,
  String? email,
  String? phoneE164,
  String? subscriptionStatus,
  String? trialEndsAt,
  String? createdAt,
}) =>
    {
      'id': id ?? 'user-1',
      'display_name': displayName ?? 'Test User',
      'avatar_url': avatarUrl,
      'bio': bio,
      'email': email ?? 'test@test.com',
      'phone_e164': phoneE164,
      'subscription_status': subscriptionStatus ?? 'free',
      'trial_ends_at': trialEndsAt,
      'created_at': createdAt ?? '2025-01-01T00:00:00.000Z',
    };

Map<String, dynamic> postMediaJson({
  String? id,
  String? postId,
  int? position,
  String? mediaUrl,
  String? mediaType,
  int? width,
  int? height,
  String? thumbnailUrl,
}) =>
    {
      'id': id ?? 'media-1',
      'post_id': postId ?? 'post-1',
      'position': position ?? 0,
      'media_url': mediaUrl ?? 'https://example.com/photo.jpg',
      'media_type': mediaType ?? 'photo',
      'width': width,
      'height': height,
      'thumbnail_url': thumbnailUrl,
    };

Map<String, dynamic> postCommentJson({
  String? id,
  String? userId,
  String? body,
  String? displayName,
  String? avatarUrl,
  String? createdAt,
}) =>
    {
      'id': id ?? 'pc-1',
      'user_id': userId ?? 'user-2',
      'body': body ?? 'Nice photo!',
      'display_name': displayName ?? 'Commenter',
      'avatar_url': avatarUrl,
      'created_at': createdAt ?? '2025-01-01T12:00:00.000Z',
    };

Map<String, dynamic> postJson({
  String? id,
  String? userId,
  String? caption,
  String? createdAt,
  String? updatedAt,
  String? deletedAt,
  List<Map<String, dynamic>>? media,
  String? displayName,
  String? avatarUrl,
  int? commentCount,
  List<Map<String, dynamic>>? recentComments,
  int? likeCount,
  bool? isLiked,
  String? expiresAt,
}) =>
    {
      'id': id ?? 'post-1',
      'user_id': userId ?? 'user-1',
      'caption': caption,
      'created_at': createdAt ?? '2025-01-01T00:00:00.000Z',
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
      'media': media ?? [postMediaJson()],
      'display_name': displayName ?? 'Test User',
      'avatar_url': avatarUrl,
      'comment_count': commentCount ?? 0,
      'recent_comments': recentComments,
      'like_count': likeCount ?? 0,
      'is_liked': isLiked ?? false,
      'expires_at': expiresAt,
    };

Map<String, dynamic> commentJson({
  String? id,
  String? postId,
  String? userId,
  String? body,
  String? createdAt,
  String? updatedAt,
  String? deletedAt,
  String? displayName,
  String? avatarUrl,
  String? replyToCommentId,
  String? replyToUserId,
  String? replyToDisplayName,
  int? likeCount,
  bool? isLiked,
}) =>
    {
      'id': id ?? 'comment-1',
      'post_id': postId ?? 'post-1',
      'user_id': userId ?? 'user-2',
      'body': body ?? 'Great post!',
      'created_at': createdAt ?? '2025-01-01T12:00:00.000Z',
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
      'display_name': displayName ?? 'Commenter',
      'avatar_url': avatarUrl,
      'reply_to_comment_id': replyToCommentId,
      'reply_to_user_id': replyToUserId,
      'reply_to_display_name': replyToDisplayName,
      'like_count': likeCount ?? 0,
      'is_liked': isLiked ?? false,
    };

Map<String, dynamic> conversationJson({
  String? id,
  String? createdAt,
  String? lastMessageAt,
  String? otherUserId,
  String? otherDisplayName,
  String? otherAvatarUrl,
  dynamic unreadCount,
  String? lastReadAt,
}) =>
    {
      'id': id ?? 'conv-1',
      'created_at': createdAt ?? '2025-01-01T00:00:00.000Z',
      'last_message_at': lastMessageAt,
      'other_user_id': otherUserId ?? 'user-2',
      'other_display_name': otherDisplayName ?? 'Other User',
      'other_avatar_url': otherAvatarUrl,
      'unread_count': unreadCount ?? 0,
      'last_read_at': lastReadAt,
    };

Map<String, dynamic> messageJson({
  String? id,
  String? conversationId,
  String? senderId,
  String? body,
  String? mediaUrl,
  String? createdAt,
  String? senderDisplayName,
  String? senderAvatarUrl,
}) =>
    {
      'id': id ?? 'msg-1',
      'conversation_id': conversationId ?? 'conv-1',
      'sender_id': senderId ?? 'user-1',
      'body': body ?? 'Hello!',
      'media_url': mediaUrl,
      'created_at': createdAt ?? '2025-01-01T12:00:00.000Z',
      'sender_display_name': senderDisplayName ?? 'Test User',
      'sender_avatar_url': senderAvatarUrl,
    };

Map<String, dynamic> storyJson({
  String? id,
  String? userId,
  String? mediaUrl,
  String? mediaType,
  String? expiresAt,
  String? createdAt,
  String? displayName,
  String? avatarUrl,
}) =>
    {
      'id': id ?? 'story-1',
      'user_id': userId ?? 'user-1',
      'media_url': mediaUrl ?? 'https://example.com/story.jpg',
      'media_type': mediaType ?? 'photo',
      'expires_at': expiresAt ?? '2025-01-02T00:00:00.000Z',
      'created_at': createdAt ?? '2025-01-01T00:00:00.000Z',
      'display_name': displayName ?? 'Test User',
      'avatar_url': avatarUrl,
    };

Map<String, dynamic> storyGroupJson({
  String? userId,
  String? displayName,
  String? avatarUrl,
  List<Map<String, dynamic>>? stories,
  bool nested = false,
}) {
  final storiesList = stories ?? [storyJson()];
  if (nested) {
    return {
      'user': {
        'id': userId ?? 'user-1',
        'display_name': displayName ?? 'Test User',
        'avatar_url': avatarUrl,
      },
      'stories': storiesList,
    };
  }
  return {
    'user_id': userId ?? 'user-1',
    'display_name': displayName ?? 'Test User',
    'avatar_url': avatarUrl,
    'stories': storiesList,
  };
}

Map<String, dynamic> groupJson({
  String? id,
  String? userId,
  String? name,
  String? color,
  int? position,
  String? createdAt,
}) =>
    {
      'id': id ?? 'group-1',
      'user_id': userId ?? 'user-1',
      'name': name ?? 'Close Friends',
      'color': color,
      'position': position ?? 0,
      'created_at': createdAt ?? '2025-01-01T00:00:00.000Z',
    };

Map<String, dynamic> inviteJson({
  String? id,
  String? code,
  String? status,
  String? expiresAt,
  String? createdAt,
  String? usedByUserId,
  String? usedAt,
}) =>
    {
      'id': id ?? 'invite-1',
      'code': code ?? 'ABC123',
      'status': status ?? 'pending',
      'expires_at': expiresAt ?? '2025-02-01T00:00:00.000Z',
      'created_at': createdAt ?? '2025-01-01T00:00:00.000Z',
      'used_by_user_id': usedByUserId,
      'used_at': usedAt,
    };

// ── Model builders ──────────────────────────────────────────

User testUser({String? id, String? displayName}) =>
    User.fromJson(userJson(id: id, displayName: displayName));

Post testPost({String? id, int mediaCount = 1}) => Post.fromJson(postJson(
      id: id,
      media: List.generate(mediaCount, (i) => postMediaJson(id: 'media-$i')),
    ));

Comment testComment({String? id}) => Comment.fromJson(commentJson(id: id));

Conversation testConversation({String? id}) =>
    Conversation.fromJson(conversationJson(id: id));

Message testMessage({String? id}) => Message.fromJson(messageJson(id: id));

Story testStory({String? id}) => Story.fromJson(storyJson(id: id));

Group testGroup({String? id}) => Group.fromJson(groupJson(id: id));

Invite testInvite({String? id}) => Invite.fromJson(inviteJson(id: id));
