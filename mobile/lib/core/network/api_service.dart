import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';
import 'api_endpoints.dart';

/// High-level service that provides typed methods for every A/SIDE API endpoint.
///
/// All methods return the raw response data (`dynamic`) so callers can parse
/// it into domain models as needed.
class ApiService {
  final ApiClient _client;

  ApiService(this._client);

  Dio get _dio => _client.dio;

  /// Shared no-auth Dio instance for presigned URL uploads.
  /// S3 presigned URLs reject any Authorization header, and spinning up a
  /// fresh client per upload is wasteful. One pooled instance handles all
  /// presigned PUTs app-wide.
  static final Dio _uploadDio = Dio(
    BaseOptions(
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  /// Upload raw bytes to a presigned URL. Uses the shared [_uploadDio] so no
  /// auth interceptor is applied — matches production behavior where S3
  /// presigned URLs don't accept auth headers.
  ///
  /// [onSendProgress] receives `(sentBytes, totalBytes)` for progress UI.
  /// [cancelToken] can be used to abort an in-flight upload (e.g. stall watchdog).
  Future<void> uploadBytes(
    String url,
    List<int> bytes,
    String contentType, {
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    await _uploadDio.put(
      url,
      data: bytes,
      options: Options(
        headers: {
          'Content-Type': contentType,
          'Content-Length': bytes.length,
        },
      ),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
  }

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  Future<dynamic> requestOtp(String email) async {
    final response = await _dio.post(
      ApiEndpoints.requestOtp,
      data: {'email': email},
    );
    return response.data;
  }

  Future<dynamic> verifyOtp(
    String email,
    String code, {
    String? inviteCode,
    String? displayName,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.verifyOtp,
      data: {
        'email': email,
        'code': code,
        if (inviteCode != null) 'invite_code': inviteCode,
        if (displayName != null) 'display_name': displayName,
      },
    );
    return response.data;
  }

  Future<dynamic> refreshToken(String token) async {
    final response = await _dio.post(
      ApiEndpoints.refreshToken,
      data: {'refresh_token': token},
    );
    return response.data;
  }

  Future<dynamic> logout(String refreshToken) async {
    final response = await _dio.delete(
      ApiEndpoints.logout,
      data: {'refresh_token': refreshToken},
    );
    return response.data;
  }

  // ---------------------------------------------------------------------------
  // Users — backend wraps in { user: ... }
  // ---------------------------------------------------------------------------

  Future<dynamic> getMe() async {
    final response = await _dio.get(ApiEndpoints.me);
    return response.data; // { user, plan_limits }
  }

  /// Build 38: tells the server we just viewed the Home feed. Bumps
  /// `users.last_feed_seen_at` so the server-computed app-icon
  /// badge count stops counting older posts as unread.
  ///
  /// Fire-and-forget — UI doesn't depend on the response. Errors
  /// are swallowed by the caller (worst case: badge count is
  /// slightly stale until the next foreground).
  Future<void> markFeedSeen() async {
    await _dio.post(ApiEndpoints.feedSeen);
  }

  Future<dynamic> updateMe({
    String? displayName,
    String? bio,
    String? avatarUrl,
  }) async {
    final response = await _dio.patch(
      ApiEndpoints.me,
      data: {
        if (displayName != null) 'display_name': displayName,
        if (bio != null) 'bio': bio,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
      },
    );
    return response.data['user'];
  }

  Future<dynamic> getAvatarUploadUrl(String contentType) async {
    final response = await _dio.post(
      ApiEndpoints.avatarUploadUrl,
      data: {'content_type': contentType},
    );
    return response.data;
  }

  Future<dynamic> getUser(String userId) async {
    final response = await _dio.get(ApiEndpoints.user(userId));
    return response.data['user'];
  }

  Future<dynamic> searchUsers(String query) async {
    final response = await _dio.get(ApiEndpoints.searchUsers(query));
    return response.data['users'] ?? response.data;
  }

  Future<dynamic> deleteMe() async {
    final response = await _dio.delete(ApiEndpoints.me);
    return response.data;
  }

  // ---------------------------------------------------------------------------
  // Notification Preferences
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getNotificationPreferences() async {
    final response = await _dio.get(ApiEndpoints.notificationPreferences);
    return Map<String, dynamic>.from(
        response.data['notification_preferences'] as Map);
  }

  Future<Map<String, dynamic>> updateNotificationPreferences(
      Map<String, bool> prefs) async {
    final response = await _dio.patch(
      ApiEndpoints.notificationPreferences,
      data: prefs,
    );
    return Map<String, dynamic>.from(
        response.data['notification_preferences'] as Map);
  }

  // ---------------------------------------------------------------------------
  // Subscriptions
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getSubscriptionStatus() async {
    final response = await _dio.get(ApiEndpoints.subscriptionStatus);
    return Map<String, dynamic>.from(response.data['subscription'] as Map);
  }

  Future<void> addFamilyMember(String userId) async {
    await _dio.post(
      ApiEndpoints.familyMembers,
      data: {'user_id': userId},
    );
  }

  Future<void> removeFamilyMember(String userId) async {
    await _dio.delete(ApiEndpoints.removeFamilyMember(userId));
  }

  Future<void> leaveFamily() async {
    await _dio.post(ApiEndpoints.leaveFamily);
  }

  // ---------------------------------------------------------------------------
  // Follows — backend wraps in { users: [...] }
  // ---------------------------------------------------------------------------

  Future<dynamic> follow(String userId) async {
    final response = await _dio.post(
      ApiEndpoints.follows,
      data: {'user_id': userId},
    );
    return response.data;
  }

  Future<dynamic> unfollow(String userId) async {
    final response = await _dio.delete(ApiEndpoints.unfollow(userId));
    return response.data;
  }

  Future<dynamic> getMutualFollows() async {
    final response = await _dio.get(ApiEndpoints.mutualFollows);
    return response.data['users'];
  }

  Future<dynamic> getUserConnections(String userId) async {
    final response = await _dio.get(ApiEndpoints.userConnections(userId));
    return response.data['users'];
  }

  Future<dynamic> getInboundFollows() async {
    final response = await _dio.get(ApiEndpoints.inboundFollows);
    return response.data['users'];
  }

  Future<dynamic> getOutboundFollows() async {
    final response = await _dio.get(ApiEndpoints.outboundFollows);
    return response.data['users'];
  }

  // ---------------------------------------------------------------------------
  // Invites — backend wraps in { invites: [...] }
  // ---------------------------------------------------------------------------

  Future<dynamic> getInvites() async {
    final response = await _dio.get(ApiEndpoints.invites);
    return response.data['invites'];
  }

  Future<dynamic> createInvite() async {
    final response = await _dio.post(ApiEndpoints.invites);
    return response.data;
  }

  Future<dynamic> markInviteSent(String id) async {
    final response = await _dio.patch(
      ApiEndpoints.updateInvite(id),
      data: {'status': 'sent'},
    );
    return response.data;
  }

  Future<dynamic> revokeInvite(String id) async {
    final response = await _dio.delete(ApiEndpoints.revokeInvite(id));
    return response.data;
  }

  Future<dynamic> validateInvite(String code) async {
    final response = await _dio.get(ApiEndpoints.validateInvite(code));
    return response.data;
  }

  Future<dynamic> redeemInvite(String code) async {
    final response = await _dio.post(
      ApiEndpoints.redeemInvite,
      data: {'code': code},
    );
    return response.data;
  }

  // ---------------------------------------------------------------------------
  // Personal invite link — slug-based replacement for codes
  // ---------------------------------------------------------------------------

  /// Fetch the caller's current invite link (slug + URL).
  /// Returns `{ slug: String, url: String }`.
  Future<Map<String, dynamic>> getInviteLink() async {
    final response = await _dio.get(ApiEndpoints.inviteLink);
    return Map<String, dynamic>.from(response.data);
  }

  /// Rotate the caller's invite slug, invalidating every previously-
  /// shared URL and QR. Returns the new `{ slug, url }`.
  Future<Map<String, dynamic>> regenerateInviteLink() async {
    final response = await _dio.post(ApiEndpoints.regenerateInviteLink);
    return Map<String, dynamic>.from(response.data);
  }

  /// Send a follow request to the user behind [slug] (or a URL that
  /// embeds a slug; the server's `extractSlug` handles both).
  /// Returns `{ status: 'requested' | 'already_following' |
  /// 'already_mutual' | 'self' }`.
  Future<Map<String, dynamic>> requestFromSlug(String slugOrUrl) async {
    final response = await _dio.post(
      ApiEndpoints.requestInviteLink,
      data: {'slug': slugOrUrl},
    );
    return Map<String, dynamic>.from(response.data);
  }

  /// Look up a user by their invite slug. Used by the "Send request
  /// to [Name]?" confirmation screen — returns the minimal payload
  /// `{ id, display_name, avatar_url }`. Throws DioException with
  /// 404 if the slug is unknown.
  Future<Map<String, dynamic>> getUserBySlug(String slug) async {
    final response = await _dio.get(ApiEndpoints.userBySlug(slug));
    return Map<String, dynamic>.from(response.data['user']);
  }

  /// Decline an inbound follow request from [userId]. Idempotent —
  /// the server returns 204 whether the request still existed or
  /// had already been dismissed elsewhere.
  Future<void> declineInbound(String userId) async {
    await _dio.delete(ApiEndpoints.declineInbound(userId));
  }

  // ---------------------------------------------------------------------------
  // Feed — backend wraps in { posts: [...] }
  // ---------------------------------------------------------------------------

  /// Fetches the feed. Returns the full response envelope so callers
  /// can read both `posts` and `has_older_posts` (the plan-gate flag
  /// the server only sets on the initial page).
  Future<Map<String, dynamic>> getFeed(
      {String? before, String? groupId}) async {
    final response = await _dio.get(
      ApiEndpoints.feed,
      queryParameters: {
        if (before != null) 'before': before,
        if (groupId != null) 'group_id': groupId,
      },
    );
    return (response.data as Map).cast<String, dynamic>();
  }

  // ---------------------------------------------------------------------------
  // Posts — backend wraps in { post: ... } or { posts: [...] }
  // ---------------------------------------------------------------------------

  Future<dynamic> getUploadUrls(String contentType, {int? count}) async {
    final response = await _dio.post(
      ApiEndpoints.postUploadUrl,
      data: {
        'content_type': contentType,
        if (count != null) 'count': count,
      },
    );
    return response.data['uploads'];
  }

  Future<dynamic> createPost({
    String? caption,
    List<Map<String, dynamic>>? media,
    List<String>? groupIds,
    bool hideAfter24h = false,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.posts,
      data: {
        if (caption != null) 'caption': caption,
        if (media != null) 'media': media,
        if (groupIds != null) 'group_ids': groupIds,
        if (hideAfter24h) 'hide_after_24h': true,
      },
    );
    return response.data['post'];
  }

  Future<dynamic> getPost(String id) async {
    final response = await _dio.get(ApiEndpoints.post(id));
    return response.data['post'];
  }

  Future<dynamic> deletePost(String id) async {
    final response = await _dio.delete(ApiEndpoints.post(id));
    return response.data;
  }

  Future<dynamic> likePost(String id) async {
    final response = await _dio.post(ApiEndpoints.likePost(id));
    return response.data;
  }

  Future<dynamic> unlikePost(String id) async {
    final response = await _dio.delete(ApiEndpoints.likePost(id));
    return response.data;
  }

  /// Build 39: list of users who liked a post. Returns a list of
  /// `{ id, display_name, avatar_url }`. Powers the long-press
  /// "Liked by" sheet — see widgets/likes_sheet.dart.
  Future<List<dynamic>> getPostLikes(String postId) async {
    final response = await _dio.get(ApiEndpoints.postLikes(postId));
    return (response.data['likes'] as List<dynamic>?) ?? const [];
  }

  /// 1.2: idempotent toggle of an emoji reaction on a post.
  /// Returns the post's full reactions summary `[{emoji, count,
  /// reacted_by_me}]` after the toggle so the caller can replace
  /// state in one shot rather than computing a delta.
  Future<List<dynamic>> togglePostReaction(String postId, String emoji) async {
    final response = await _dio.post(
      ApiEndpoints.togglePostReaction(postId),
      data: {'emoji': emoji},
    );
    return (response.data['reactions'] as List<dynamic>?) ?? const [];
  }

  /// 1.2: list of users who reacted with a specific emoji on a
  /// post — backs the long-press-on-chip sheet.
  /// Returns `{ id, display_name, avatar_url, reacted_at }`.
  Future<List<dynamic>> getPostReactionUsers(
    String postId,
    String emoji, {
    String? before,
  }) async {
    final response = await _dio.get(
      ApiEndpoints.postReactionUsers(postId, emoji),
      queryParameters: {
        if (before != null) 'before': before,
      },
    );
    return (response.data['users'] as List<dynamic>?) ?? const [];
  }

  Future<dynamic> getUserPosts(String userId, {String? before}) async {
    final response = await _dio.get(
      ApiEndpoints.userPosts(userId),
      queryParameters: {
        if (before != null) 'before': before,
      },
    );
    return response.data['posts'];
  }

  // ---------------------------------------------------------------------------
  // Comments — backend wraps in { comments: [...] } or { comment: ... }
  // ---------------------------------------------------------------------------

  Future<dynamic> getComments(String postId) async {
    final response = await _dio.get(ApiEndpoints.comments(postId));
    return response.data['comments'];
  }

  Future<dynamic> createComment(
    String postId,
    String body, {
    String? replyToCommentId,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.comments(postId),
      data: {
        'body': body,
        if (replyToCommentId != null) 'reply_to_comment_id': replyToCommentId,
      },
    );
    return response.data['comment'];
  }

  /// Like a comment. Idempotent — safe to call twice. Returns the new
  /// `{ liked, like_count }`.
  Future<dynamic> likeComment(String id) async {
    final response = await _dio.post(ApiEndpoints.likeComment(id));
    return response.data;
  }

  /// Unlike a comment. Idempotent.
  Future<dynamic> unlikeComment(String id) async {
    final response = await _dio.delete(ApiEndpoints.likeComment(id));
    return response.data;
  }

  /// Build 39: list of users who liked a comment. Same shape as
  /// getPostLikes — feeds the same LikesSheet widget.
  Future<List<dynamic>> getCommentLikes(String commentId) async {
    final response = await _dio.get(ApiEndpoints.commentLikes(commentId));
    return (response.data['likes'] as List<dynamic>?) ?? const [];
  }

  Future<dynamic> editComment(String id, String body) async {
    final response = await _dio.put(
      ApiEndpoints.editComment(id),
      data: {'body': body},
    );
    return response.data['comment'];
  }

  Future<dynamic> deleteComment(String id) async {
    final response = await _dio.delete(ApiEndpoints.deleteComment(id));
    return response.data;
  }

  Future<dynamic> editPostCaption(String id, String caption) async {
    final response = await _dio.patch(
      ApiEndpoints.post(id),
      data: {'caption': caption},
    );
    return response.data['post'];
  }

  // ---------------------------------------------------------------------------
  // Stories — backend wraps in { story_groups: [...] }
  // ---------------------------------------------------------------------------

  Future<dynamic> getStories() async {
    final response = await _dio.get(ApiEndpoints.stories);
    return response.data['story_groups'];
  }

  Future<dynamic> getStoryUploadUrl(String contentType) async {
    final response = await _dio.post(
      ApiEndpoints.storyUploadUrl,
      data: {'content_type': contentType},
    );
    return response.data;
  }

  Future<dynamic> createStory(String key, String mediaType) async {
    final response = await _dio.post(
      ApiEndpoints.stories,
      data: {
        'key': key,
        'media_type': mediaType,
      },
    );
    return response.data['story'];
  }

  Future<dynamic> deleteStory(String id) async {
    final response = await _dio.delete(ApiEndpoints.deleteStory(id));
    return response.data;
  }

  // ---------------------------------------------------------------------------
  // Conversations — backend wraps in { conversations: [...] }, { messages: [...] }, etc.
  // ---------------------------------------------------------------------------

  Future<dynamic> getConversations() async {
    final response = await _dio.get(ApiEndpoints.conversations);
    return response.data['conversations'];
  }

  /// Fetch a single conversation by id. Returns the full enriched
  /// shape (including is_e2ee, other user info or members list)
  /// even when the conversation has no messages yet — which is
  /// when the detail screen needs it for a fresh send path.
  Future<Map<String, dynamic>> getConversationById(String id) async {
    final response = await _dio.get(ApiEndpoints.conversationById(id));
    return Map<String, dynamic>.from(response.data['conversation'] as Map);
  }

  /// Opens (or re-fetches) a 1:1 conversation. New conversations
  /// default to E2EE so users get Signal-Protocol encryption
  /// out-of-the-box. Existing plaintext conversations with the
  /// same peer are returned unchanged — server dedupe by (user_a,
  /// user_b) doesn't flip is_e2ee on a pre-existing row.
  Future<dynamic> createConversation(String userId) async {
    final response = await _dio.post(
      ApiEndpoints.conversations,
      data: {'user_id': userId, 'is_e2ee': true},
    );
    return response.data['conversation'];
  }

  /// Create a group DM with [memberIds] (1-9 other mutual follows) and
  /// [name]. The creator is added automatically — don't include the
  /// current user in [memberIds].
  ///
  /// Phase 1f: new groups default to E2EE (Sender Keys) to match the
  /// 1:1 behaviour. Legacy plaintext groups exist only for pre-E2EE
  /// conversations that predate this build; once those are gone, the
  /// `is_e2ee=false` branch on the server can be removed.
  Future<dynamic> createGroupConversation({
    required List<String> memberIds,
    required String name,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.conversations,
      data: {
        'member_ids': memberIds,
        'name': name,
        'is_e2ee': true,
      },
    );
    return response.data['conversation'];
  }

  /// Rename a group conversation (creator only).
  Future<dynamic> renameConversation(String id, String name) async {
    final response = await _dio.patch(
      ApiEndpoints.conversation(id),
      data: {'name': name},
    );
    return response.data['conversation'];
  }

  /// Add members to a group conversation (creator only).
  Future<dynamic> addConversationMembers(
    String id,
    List<String> userIds,
  ) async {
    final response = await _dio.post(
      ApiEndpoints.conversationMembers(id),
      data: {'user_ids': userIds},
    );
    return response.data['conversation'];
  }

  /// Remove a single member from a group conversation (creator only).
  Future<void> removeConversationMember(String id, String userId) async {
    await _dio.delete(ApiEndpoints.conversationMember(id, userId));
  }

  /// Leave a group conversation. If you were the last member, the
  /// conversation is dissolved server-side (response `dissolved: true`).
  ///
  /// If the caller is the creator AND other members remain, the server
  /// requires [newAdminId] — one of the current members, to whom admin
  /// is transferred before the caller is removed. Without it, the
  /// server responds 400 with `requires_admin_transfer: true`, which
  /// the caller can use to prompt for a pick.
  Future<dynamic> leaveConversation(String id, {String? newAdminId}) async {
    final response = await _dio.post(
      ApiEndpoints.leaveConversation(id),
      data: newAdminId == null ? null : {'new_admin_id': newAdminId},
    );
    return response.data;
  }

  Future<dynamic> getMessages(String conversationId, {String? before}) async {
    final response = await _dio.get(
      ApiEndpoints.messages(conversationId),
      queryParameters: {
        if (before != null) 'before': before,
      },
    );
    return response.data;
  }

  /// Sends a message. Two modes:
  ///
  /// - Legacy plaintext: pass [body] and/or [mediaUrl]. Works on
  ///   conversations where `is_e2ee = false`. Server rejects this
  ///   path on E2EE conversations.
  ///
  /// - E2EE envelope: pass [ciphertextBase64] + [envelopeType] +
  ///   [protocolVersion]. The ciphertext is libsignal's serialized
  ///   CiphertextMessage (PKM or SignalMessage, distinguished by
  ///   `protocol_version` — 2 = PreKey, 3 = Signal). Server rejects
  ///   this path on legacy conversations.
  ///
  /// Callers shouldn't pass both sets — the server will reject that.
  Future<dynamic> sendMessage(
    String conversationId, {
    String? body,
    String? mediaUrl,
    String? ciphertextBase64,
    String? envelopeType,
    int? protocolVersion,
    int? conversationEpoch,
    // Phase 1f: for `envelope_type == 'signal_skdm'` control rows,
    // targets a single member of the group so only that user
    // receives the row on fetch + socket. Server rejects this field
    // on any other envelope type.
    String? recipientId,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.messages(conversationId),
      data: {
        if (body != null) 'body': body,
        if (mediaUrl != null) 'media_url': mediaUrl,
        if (ciphertextBase64 != null) 'ciphertext': ciphertextBase64,
        if (envelopeType != null) 'envelope_type': envelopeType,
        if (protocolVersion != null) 'protocol_version': protocolVersion,
        if (conversationEpoch != null) 'conversation_epoch': conversationEpoch,
        if (recipientId != null) 'recipient_id': recipientId,
      },
    );
    return response.data['message'];
  }

  Future<dynamic> getConversationUploadUrl(
    String conversationId,
    String contentType,
  ) async {
    final response = await _dio.get(
      ApiEndpoints.conversationUploadUrl(conversationId),
      queryParameters: {'content_type': contentType},
    );
    return response.data;
  }

  Future<dynamic> markAsRead(String conversationId) async {
    final response = await _dio.post(
      ApiEndpoints.markRead(conversationId),
    );
    return response.data;
  }

  // ---------------------------------------------------------------------------
  // Lists — user-facing name for curated friend lists. Server response shape
  // still uses the internal `groups` / `group` JSON keys for zero migration;
  // only the paths and Dart method names changed. See ApiEndpoints.lists.
  // ---------------------------------------------------------------------------

  Future<dynamic> getLists() async {
    final response = await _dio.get(ApiEndpoints.lists);
    return response.data['groups'];
  }

  Future<dynamic> createList(
    String name, {
    String? color,
    int? position,
  }) async {
    final response = await _dio.post(
      ApiEndpoints.lists,
      data: {
        'name': name,
        if (color != null) 'color': color,
        if (position != null) 'position': position,
      },
    );
    return response.data['group'];
  }

  Future<dynamic> updateList(
    String id, {
    String? name,
    String? color,
    int? position,
  }) async {
    final response = await _dio.patch(
      ApiEndpoints.list(id),
      data: {
        if (name != null) 'name': name,
        if (color != null) 'color': color,
        if (position != null) 'position': position,
      },
    );
    return response.data['group'];
  }

  Future<dynamic> deleteList(String id) async {
    final response = await _dio.delete(ApiEndpoints.list(id));
    return response.data;
  }

  Future<dynamic> getListMembers(String id) async {
    final response = await _dio.get(ApiEndpoints.listMembers(id));
    return response.data['members'];
  }

  Future<dynamic> setListMembers(String id, List<String> userIds) async {
    final response = await _dio.put(
      ApiEndpoints.listMembers(id),
      data: {'user_ids': userIds},
    );
    return response.data;
  }

  // ── Contacts (discovery) ────────────────────────────

  Future<dynamic> syncContacts(List<String> hashes) async {
    final response = await _dio.post(
      ApiEndpoints.contactsSync,
      data: {'hashes': hashes},
    );
    return response.data['matches'];
  }

  Future<dynamic> getContactMatches() async {
    final response = await _dio.get(ApiEndpoints.contactsMatches);
    return response.data['matches'];
  }

  // ── Devices (push notifications) ────────────────────────────

  Future<void> registerDeviceToken(String token, String platform) async {
    await _dio.post(
      ApiEndpoints.deviceToken,
      data: {'token': token, 'platform': platform},
    );
  }

  Future<void> unregisterDeviceToken(String token) async {
    await _dio.delete(
      ApiEndpoints.deviceToken,
      data: {'token': token},
    );
  }

  // ── E2EE key registry (Phase 1c) ────────────────────────────
  //
  // These accept already-formed JSON maps (see PublicKeyBundle.toJson,
  // PublicSignedPreKey.toJson, PublicOneTimePreKey.toJson on the
  // SignalClient side) so ApiService stays a thin transport layer —
  // no crypto knowledge leaks into it.

  /// First-run bundle upload. Server 409s if an active key set
  /// already exists (caller should revokeKeys() before re-uploading).
  Future<void> uploadDeviceKeys(Map<String, dynamic> bundleJson) async {
    await _dio.post(ApiEndpoints.deviceKeysUpload, data: bundleJson);
  }

  /// Adds more prekeys (OTPK and/or Kyber) to the current key set.
  /// Both lists are optional — pass whatever was freshly generated.
  Future<void> replenishPreKeys({
    List<Map<String, dynamic>> oneTimePreKeys = const [],
    List<Map<String, dynamic>> kyberPreKeys = const [],
  }) async {
    if (oneTimePreKeys.isEmpty && kyberPreKeys.isEmpty) return;
    final body = <String, dynamic>{};
    if (oneTimePreKeys.isNotEmpty) {
      body['one_time_prekeys'] = oneTimePreKeys;
    }
    if (kyberPreKeys.isNotEmpty) {
      body['kyber_prekeys'] = kyberPreKeys;
    }
    await _dio.post(ApiEndpoints.deviceKeysReplenish, data: body);
  }

  /// Swaps the signed prekey. Called weekly.
  Future<void> rotateSignedPreKey(Map<String, dynamic> signedPreKeyJson) async {
    await _dio.post(
      ApiEndpoints.deviceKeysRotateSigned,
      data: {'signed_prekey': signedPreKeyJson},
    );
  }

  /// Marks the current key set revoked on the server. Client should
  /// pair with SignalClient.wipeKeys() for a full reset.
  Future<void> revokeDeviceKeys() async {
    await _dio.post(ApiEndpoints.deviceKeysRevoke);
  }

  /// Fetches a peer's key bundle for session setup. Server atomically
  /// consumes one OTPK if available; `one_time_prekey` may be null
  /// if the target's pool is empty (weaker forward secrecy fallback).
  Future<Map<String, dynamic>> getUserKeyBundle(String userId) async {
    final response = await _dio.get(ApiEndpoints.userKeyBundle(userId));
    return Map<String, dynamic>.from(response.data as Map);
  }

  // ── E2EE DM attachments (Phase 1g) ──────────────────────────

  /// Request a presigned PUT URL + opaque `dm/<uuid>` key for
  /// uploading an encrypted attachment blob.
  Future<Map<String, dynamic>> getDMAttachmentUploadUrl(
      String contentType) async {
    final response = await _dio.post(
      ApiEndpoints.dmAttachmentUploadUrl,
      data: {'content_type': contentType},
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// Request a short-TTL presigned GET URL for downloading an
  /// attachment blob by its `<uuid>` (the part after the `dm/`).
  Future<String> getDMAttachmentDownloadUrl(String attachmentId) async {
    final response = await _dio.get(
      ApiEndpoints.dmAttachmentDownloadUrl(attachmentId),
    );
    return (response.data as Map)['download_url'] as String;
  }

  /// Raw download of attachment ciphertext bytes. No auth header —
  /// the presigned URL embeds its own authorization.
  Future<Uint8List> downloadAttachmentCiphertext(String url) async {
    final response = await _uploadDio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data!);
  }
}
