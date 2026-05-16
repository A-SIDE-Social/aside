class ApiEndpoints {
  static const base = '/v1';

  // Auth
  static const requestOtp = '$base/auth/request-otp';
  static const verifyOtp = '$base/auth/verify-otp';
  static const refreshToken = '$base/auth/refresh';
  static const logout = '$base/auth/session';

  // Users
  static const me = '$base/users/me';
  static const avatarUploadUrl = '$base/users/me/upload-url';
  // Build 38: bumps users.last_feed_seen_at = NOW(). Drives the
  // post-side of the app-icon badge count.
  static const feedSeen = '$base/users/me/feed-seen';
  static String user(String id) => '$base/users/$id';

  // Follows
  static const follows = '$base/follows';
  static String unfollow(String userId) => '$base/follows/$userId';
  static const mutualFollows = '$base/follows/mutual';
  static String userConnections(String userId) =>
      '$base/follows/mutual/$userId';
  static const inboundFollows = '$base/follows/inbound';
  static const outboundFollows = '$base/follows/outbound';

  // Invites
  static const invites = '$base/invites';
  static String updateInvite(String id) => '$base/invites/$id';
  static String revokeInvite(String id) => '$base/invites/$id';
  static String validateInvite(String code) => '$base/invites/validate/$code';
  static const redeemInvite = '$base/invites/redeem';

  // Personal invite link — opaque-slug URL that replaces invite codes
  // as the primary share affordance. `inviteLink` returns the caller's
  // own slug + URL; `regenerateInviteLink` rotates it; `requestInviteLink`
  // sends a follow request to someone else via their slug. Lookup by
  // slug for the in-app "Send request to [Name]?" confirmation lives
  // under /users/by-slug/.
  static const inviteLink = '$base/invite-link';
  static const regenerateInviteLink = '$base/invite-link/regenerate';
  static const requestInviteLink = '$base/invite-link/request';
  static String userBySlug(String slug) => '$base/users/by-slug/$slug';

  // Decline an inbound follow request — distinct from /unfollow,
  // which removes a follow where the caller is the FOLLOWER. This
  // path removes a follow where the caller is the FOLLOWEE.
  static String declineInbound(String userId) =>
      '$base/follows/inbound/$userId';

  // Feed
  static const feed = '$base/feed';

  // Posts
  static const posts = '$base/posts';
  static const postUploadUrl = '$base/posts/upload-url';
  static String post(String id) => '$base/posts/$id';
  static String likePost(String id) => '$base/posts/$id/like';
  // Build 39: list of users who liked a post — powers the long-press
  // "Liked by" sheet. Mirror endpoint for comments below.
  static String postLikes(String id) => '$base/posts/$id/likes';
  static String userPosts(String userId) => '$base/posts/by-user/$userId';

  // Reactions (1.2): emoji reactions on posts. Toggle is idempotent —
  // if the user already reacted with that emoji, removes it; else
  // inserts. Users endpoint backs the long-press sheet that lists
  // who reacted with a particular emoji.
  static String togglePostReaction(String id) =>
      '$base/posts/$id/reactions/toggle';
  static String postReactionUsers(String id, String emoji) =>
      '$base/posts/$id/reactions/${Uri.encodeComponent(emoji)}/users';

  // Comments
  static String comments(String postId) => '$base/posts/$postId/comments';
  static String editComment(String id) => '$base/comments/$id';
  static String deleteComment(String id) => '$base/comments/$id';
  static String likeComment(String id) => '$base/comments/$id/like';
  static String commentLikes(String id) => '$base/comments/$id/likes';

  // Stories
  static const stories = '$base/stories';
  static const storyUploadUrl = '$base/stories/upload-url';
  static String deleteStory(String id) => '$base/stories/$id';

  // Conversations
  static const conversations = '$base/conversations';
  // Single-conversation fetch by id. Used by the detail screen so a
  // just-created conversation (no messages yet) still renders with
  // its full shape — GET /conversations filters those out via the
  // last_message_at IS NOT NULL rule.
  static String conversationById(String id) => '$base/conversations/$id';
  static String conversation(String id) => '$base/conversations/$id';
  static String messages(String id) => '$base/conversations/$id/messages';
  static String conversationUploadUrl(String id) =>
      '$base/conversations/$id/upload-url';
  static String markRead(String id) => '$base/conversations/$id/read';
  static String conversationMembers(String id) =>
      '$base/conversations/$id/members';
  static String conversationMember(String id, String userId) =>
      '$base/conversations/$id/members/$userId';
  static String leaveConversation(String id) => '$base/conversations/$id/leave';

  // Search
  static String searchUsers(String query) =>
      '$base/users/search?q=${Uri.encodeComponent(query)}';

  // Devices (push notifications)
  static const deviceToken = '$base/devices/token';

  // E2EE key registry (Phase 1c)
  static const deviceKeysUpload = '$base/devices/keys/upload';
  static const deviceKeysReplenish = '$base/devices/keys/replenish';
  static const deviceKeysRotateSigned = '$base/devices/keys/rotate-signed';
  static const deviceKeysRevoke = '$base/devices/revoke';
  static String userKeyBundle(String userId) => '$base/users/$userId/keybundle';

  // E2EE DM attachments (Phase 1g)
  static const dmAttachmentUploadUrl = '$base/dm-attachments/upload-url';
  static String dmAttachmentDownloadUrl(String id) =>
      '$base/dm-attachments/$id';

  // Contacts
  static const contactsSync = '$base/contacts/sync';
  static const contactsMatches = '$base/contacts/matches';

  // Notification Preferences
  static const notificationPreferences =
      '$base/users/me/notification-preferences';

  // Subscriptions
  static const subscriptionStatus = '$base/subscriptions/status';
  static const familyMembers = '$base/subscriptions/family/members';
  static String removeFamilyMember(String id) =>
      '$base/subscriptions/family/members/$id';
  static const leaveFamily = '$base/subscriptions/family/leave';

  // Lists — user-facing name for curated friend lists (post audience +
  // feed filter). Server still exposes /groups as an alias for older
  // mobile clients during rollout; see src/routes/index.ts.
  static const lists = '$base/lists';
  static String list(String id) => '$base/lists/$id';
  static String listMembers(String id) => '$base/lists/$id/members';
}
