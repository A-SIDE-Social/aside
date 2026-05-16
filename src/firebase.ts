import admin from 'firebase-admin';
import { query } from './db/pool';

// Initialize Firebase Admin — uses GOOGLE_APPLICATION_CREDENTIALS env var
// or a service account JSON file path via FIREBASE_SERVICE_ACCOUNT_PATH
const serviceAccountPath = process.env.FIREBASE_SERVICE_ACCOUNT_PATH;

if (serviceAccountPath) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const serviceAccount = require(serviceAccountPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
} else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  admin.initializeApp();
} else {
  // For development — initialize without credentials (push won't work but app won't crash)
  try {
    admin.initializeApp();
  } catch {
    console.warn('[Firebase] No credentials found — push notifications disabled');
  }
}

/**
 * Send push notifications to a list of FCM tokens. No badge is
 * attached — these notifications shouldn't influence the app-icon
 * badge count. Use `sendPushWithBadge` when the notification
 * represents new unseen content (posts, DMs) that should bump the
 * icon.
 *
 * Automatically cleans up invalid/expired tokens from the database.
 */
export async function sendPush(
  tokens: string[],
  title: string,
  body: string,
  data?: Record<string, string>,
): Promise<void> {
  if (tokens.length === 0) return;

  try {
    const message: admin.messaging.MulticastMessage = {
      tokens,
      notification: { title, body },
      data,
      apns: {
        payload: {
          aps: {
            sound: 'default',
            // No `badge` key on purpose — see sendPushWithBadge.
            // For non-content notifications (follower requests,
            // comment activity, etc.), we don't touch the icon
            // badge.
            'content-available': 1,
          },
        },
      },
      android: {
        priority: 'high' as const,
        notification: {
          sound: 'default',
          channelId: 'default',
        },
      },
    };

    const response = await admin.messaging().sendEachForMulticast(message);

    // Clean up invalid tokens
    const tokensToRemove: string[] = [];
    response.responses.forEach((resp, idx) => {
      if (resp.error) {
        const code = resp.error.code;
        if (
          code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-registration-token'
        ) {
          tokensToRemove.push(tokens[idx]);
        }
      }
    });

    if (tokensToRemove.length > 0) {
      await query(
        'DELETE FROM device_tokens WHERE token = ANY($1)',
        [tokensToRemove],
      );
    }
  } catch (err) {
    console.error('[Firebase] Push send error:', err);
  }
}

/**
 * Compute the user's app-icon badge count.
 *
 * Two components:
 *   - New posts in their feed they haven't seen since the last
 *     time they opened Home. "Their feed" = posts authored by
 *     mutual follows. Bounded by `users.last_feed_seen_at`,
 *     which is bumped on every Home visit.
 *   - Unread DMs across all their conversations. SKDM control
 *     rows are excluded.
 *
 * Other notification types (follower requests, comment activity)
 * deliberately don't add to the badge — those don't represent
 * new content the user is "behind on."
 */
export async function getUserBadgeCount(userId: string): Promise<number> {
  const { rows } = await query(
    `SELECT
       (
         SELECT COUNT(*)::int
         FROM posts p
         WHERE p.user_id IN (
           SELECT f1.followee_id
           FROM follows f1
           JOIN follows f2
             ON f2.follower_id = f1.followee_id
            AND f2.followee_id = f1.follower_id
           WHERE f1.follower_id = u.id
         )
           AND p.created_at > COALESCE(u.last_feed_seen_at, u.created_at)
           AND p.deleted_at IS NULL
       ) +
       (
         SELECT COALESCE(SUM(unread), 0)::int
         FROM (
           SELECT COUNT(*) AS unread
           FROM messages m
           JOIN conversation_members cm
             ON cm.conversation_id = m.conversation_id
            AND cm.user_id = u.id
           WHERE m.sender_id != u.id
             AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01')
             AND m.envelope_type IS DISTINCT FROM 'signal_skdm'
           GROUP BY m.conversation_id
         ) sub
       ) AS total
     FROM users u
     WHERE u.id = $1`,
    [userId],
  );
  if (rows.length === 0) return 0;
  return Number(rows[0].total) || 0;
}

/**
 * Like `sendPush`, but computes a per-recipient badge count and
 * attaches it to each individual message. Used for new-content
 * pushes (new_post, new_dm) where the icon badge should reflect
 * the recipient's actual unread count.
 *
 * Falls back to `sendEach` (one message per token) instead of
 * `sendEachForMulticast` because the badge varies per recipient.
 * Token cleanup mirrors `sendPush`.
 */
export async function sendPushWithBadge(
  recipients: Array<{ userId: string; tokens: string[] }>,
  title: string,
  body: string,
  data?: Record<string, string>,
): Promise<void> {
  if (recipients.length === 0) return;

  // Build the per-token message list. We compute badges in
  // parallel — typical fanout is 10s of recipients, so the
  // SELECTs stay quick.
  const messages: admin.messaging.Message[] = [];
  await Promise.all(
    recipients.map(async (r) => {
      if (r.tokens.length === 0) return;
      const badge = await getUserBadgeCount(r.userId);
      for (const token of r.tokens) {
        messages.push({
          token,
          notification: { title, body },
          data,
          apns: {
            payload: {
              aps: {
                sound: 'default',
                badge,
                'content-available': 1,
              },
            },
          },
          android: {
            priority: 'high' as const,
            notification: {
              sound: 'default',
              channelId: 'default',
            },
          },
        });
      }
    }),
  );

  if (messages.length === 0) return;

  try {
    const response = await admin.messaging().sendEach(messages);

    const tokensToRemove: string[] = [];
    response.responses.forEach((resp, idx) => {
      if (resp.error) {
        const code = resp.error.code;
        if (
          code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-registration-token'
        ) {
          // `messages[idx]` was built with a `token` field above.
          const t = (messages[idx] as { token?: string }).token;
          if (t) tokensToRemove.push(t);
        }
      }
    });

    if (tokensToRemove.length > 0) {
      await query(
        'DELETE FROM device_tokens WHERE token = ANY($1)',
        [tokensToRemove],
      );
    }
  } catch (err) {
    console.error('[Firebase] Push (with badge) send error:', err);
  }
}

/**
 * Get all FCM tokens for a list of user IDs (flat list, no
 * recipient attribution). Used by `sendPush` for non-content
 * notifications where the per-recipient context doesn't matter.
 */
export async function getTokensForUsers(userIds: string[]): Promise<string[]> {
  if (userIds.length === 0) return [];
  const { rows } = await query(
    'SELECT token FROM device_tokens WHERE user_id = ANY($1)',
    [userIds],
  );
  return rows.map((r: any) => r.token);
}

// ---------------------------------------------------------------------------
// Push throttling
// ---------------------------------------------------------------------------
//
// Goal: at most one push per user per 5-minute window. The user has
// been getting one push per discrete event (a flurry of comments, a
// post + a follow at the same time, etc.), and the phone vibrates
// for each — too noisy in practice. The notification ROW is still
// inserted every time (so the in-app activity surface stays
// accurate), but the PUSH only fires if no other push has gone out
// in the last 5 minutes.
//
// Implementation reuses the `notifications.push_sent_at` column
// (declared in 001_initial.sql, never written until now). After a
// successful push, we stamp `push_sent_at = NOW()` on the most
// recent un-stamped notification for each recipient. The throttle
// check is `EXISTS notification with push_sent_at > NOW() - 5 min`.
//
// DMs bypass the throttle — they are direct conversational signal
// and a friend texting you back should buzz your phone every time.
// (Stamping still happens for DMs so other non-DM pushes get
// suppressed during an active conversation, which is desirable —
// you don't need a "new post" buzz layered on top of a DM thread.)

const PUSH_THROTTLE_INTERVAL = '5 minutes';

/**
 * Filter a list of recipient user IDs down to those who haven't
 * been pushed in the last PUSH_THROTTLE_INTERVAL. Used by
 * non-DM senders so a quiet user gets a push and a noisy user
 * doesn't get bombarded.
 *
 * Exported so call sites that aren't using sendPush directly
 * (the inline pushes in routes/follows.ts, routes/auth.ts, etc.)
 * can also apply the throttle.
 */
export async function filterByPushThrottle(
  userIds: string[],
): Promise<string[]> {
  if (userIds.length === 0) return [];
  const { rows } = await query(
    `SELECT uid::uuid FROM unnest($1::uuid[]) AS uid
     WHERE NOT EXISTS (
       SELECT 1 FROM notifications n
       WHERE n.user_id = uid
         AND n.push_sent_at > NOW() - INTERVAL '${PUSH_THROTTLE_INTERVAL}'
     )`,
    [userIds],
  );
  return rows.map((r: any) => r.uid);
}

/**
 * Stamp `push_sent_at = NOW()` on the most recent un-stamped
 * notification for each user. Called AFTER a successful push so
 * the next throttle check sees the recent activity.
 *
 * Bounded to notifications created in the last 30 seconds —
 * notifications are inserted by the route handler immediately
 * before the push fires, so a fresh push always has a fresh
 * notification row to stamp. The 30-second window guards against
 * accidentally stamping an unrelated older row if the chronology
 * gets weird (e.g. a retry running well after the inserts).
 */
export async function stampPushSent(userIds: string[]): Promise<void> {
  if (userIds.length === 0) return;
  // For each user, stamp only the single most-recent un-stamped
  // notification. Otherwise a fanout where multiple notifications
  // landed at once (rare but possible) would all get stamped, and
  // each would extend the throttle window for the next 5 min — not
  // semantically wrong, but the per-user "one stamp per push" model
  // is easier to reason about.
  await query(
    `UPDATE notifications n
     SET push_sent_at = NOW()
     FROM (
       SELECT DISTINCT ON (user_id) id
       FROM notifications
       WHERE user_id = ANY($1)
         AND push_sent_at IS NULL
         AND created_at > NOW() - INTERVAL '30 seconds'
       ORDER BY user_id, created_at DESC
     ) AS latest
     WHERE n.id = latest.id`,
    [userIds],
  );
}

/**
 * Like `getTokensForUsers` but groups tokens by recipient. Used
 * by `sendPushWithBadge` so each recipient gets a message with
 * their own badge count.
 */
export async function getTokensByUser(
  userIds: string[],
): Promise<Array<{ userId: string; tokens: string[] }>> {
  if (userIds.length === 0) return [];
  const { rows } = await query(
    'SELECT user_id, token FROM device_tokens WHERE user_id = ANY($1)',
    [userIds],
  );
  const map = new Map<string, string[]>();
  for (const row of rows) {
    if (!map.has(row.user_id)) map.set(row.user_id, []);
    map.get(row.user_id)!.push(row.token);
  }
  return Array.from(map.entries()).map(([userId, tokens]) => ({
    userId,
    tokens,
  }));
}

/**
 * Check if a single user has a specific notification preference enabled.
 * Returns true if no preference row exists (default = all enabled).
 */
async function isNotificationEnabled(userId: string, category: string): Promise<boolean> {
  const { rows } = await query(
    `SELECT COALESCE(
      (SELECT ${category} FROM notification_preferences WHERE user_id = $1),
      true
    ) AS enabled`,
    [userId],
  );
  return rows[0].enabled;
}

/**
 * Filter a list of user IDs to only those who have a specific notification
 * preference enabled. Users without a preference row default to enabled.
 */
async function filterByPreference(userIds: string[], category: string): Promise<string[]> {
  if (userIds.length === 0) return [];
  const { rows } = await query(
    `SELECT uid FROM unnest($1::uuid[]) AS uid
     WHERE NOT EXISTS (
       SELECT 1 FROM notification_preferences np
       WHERE np.user_id = uid AND np.${category} = false
     )`,
    [userIds],
  );
  return rows.map((r: any) => r.uid);
}

/**
 * Build the body string for a new-post push notification. When the poster
 * wrote a caption we use it verbatim (truncated). When there's no caption,
 * fall back to a descriptor that reflects the actual media — "photo" /
 * "video" / "carousel" — instead of always saying "photo".
 *
 * Exported for unit testing.
 */
export function buildNewPostBody(
  caption: string | null,
  mediaTypes: string[],
): string {
  const trimmed = caption?.trim();
  if (trimmed) {
    return trimmed.length > 100 ? trimmed.substring(0, 100) + '…' : trimmed;
  }

  if (mediaTypes.length === 0) return 'Shared a post';
  if (mediaTypes.length > 1) return 'Shared a carousel';

  const type = mediaTypes[0];
  if (type === 'video') return 'Shared a video';
  return 'Shared a photo';
}

/**
 * Send push notification for a new post to all mutual followers.
 */
export async function notifyNewPost(
  posterId: string,
  posterName: string,
  caption: string | null,
  postId: string,
  mediaTypes: string[] = [],
  imageUrl?: string,
): Promise<void> {
  try {
    // Find all mutual followers
    const { rows: followers } = await query(
      `SELECT f1.followee_id AS user_id
       FROM follows f1
       JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
       WHERE f1.follower_id = $1`,
      [posterId],
    );

    let recipientIds = followers.map((f: any) => f.user_id);
    if (recipientIds.length === 0) return;

    // Filter by notification preferences
    recipientIds = await filterByPreference(recipientIds, 'posts');
    if (recipientIds.length === 0) return;

    // Throttle: at most one push per recipient per 5 min. Drops any
    // recipient who's already had a push in the window. The
    // notification row was still inserted upstream so the in-app
    // activity surface remains accurate — only the device-level
    // buzz is suppressed.
    recipientIds = await filterByPushThrottle(recipientIds);
    if (recipientIds.length === 0) return;

    const recipients = await getTokensByUser(recipientIds);
    if (recipients.length === 0) return;

    const body = buildNewPostBody(caption, mediaTypes);

    const data: Record<string, string> = {
      type: 'new_post',
      post_id: postId,
      poster_name: posterName,
    };
    if (imageUrl) data.image_url = imageUrl;

    // Per-recipient badge: each user's count includes this post if
    // it lands in their feed (it does — they're a mutual follow).
    await sendPushWithBadge(recipients, posterName, body, data);
    await stampPushSent(recipientIds);
  } catch (err) {
    console.error('[Firebase] notifyNewPost error:', err);
  }
}

/**
 * Send push notification for a new comment on a post.
 *
 * Note: `commentId` is optional only for backwards-compatibility during
 * the rollout; callers in src/routes/comments.ts always pass it.
 */
export async function notifyComment(
  postAuthorId: string,
  commenterName: string,
  commentBody: string,
  postId: string,
  commentId?: string,
): Promise<void> {
  try {
    // Check if post author has comments notifications enabled
    const enabled = await isNotificationEnabled(postAuthorId, 'comments');
    if (!enabled) return;

    // Throttle (see filterByPushThrottle). Notification row was
    // already inserted by the route handler before this call.
    const allowed = await filterByPushThrottle([postAuthorId]);
    if (allowed.length === 0) return;

    const tokens = await getTokensForUsers([postAuthorId]);
    if (tokens.length === 0) return;

    const body = commentBody.length > 100
      ? commentBody.substring(0, 100) + '…'
      : commentBody;

    const data: Record<string, string> = {
      type: 'comment',
      post_id: postId,
    };
    if (commentId) data.comment_id = commentId;

    await sendPush(tokens, commenterName, body, data);
    await stampPushSent([postAuthorId]);
  } catch (err) {
    console.error('[Firebase] notifyComment error:', err);
  }
}

/**
 * Send push notification when someone replies to your comment.
 *
 * Fires once per reply-recipient regardless of whether they're also
 * the post author — the router dedupes to this single event for that
 * case (see src/routes/comments.ts).
 */
export async function notifyCommentReply(
  recipientId: string,
  replierName: string,
  commentBody: string,
  postId: string,
  commentId: string,
): Promise<void> {
  try {
    // Reuses the 'comments' preference — we don't split reply pings
    // into their own toggle yet. If users ask, we'll add one later.
    const enabled = await isNotificationEnabled(recipientId, 'comments');
    if (!enabled) return;

    const allowed = await filterByPushThrottle([recipientId]);
    if (allowed.length === 0) return;

    const tokens = await getTokensForUsers([recipientId]);
    if (tokens.length === 0) return;

    const body = commentBody.length > 100
      ? commentBody.substring(0, 100) + '…'
      : commentBody;

    await sendPush(tokens, `${replierName} replied to your comment`, body, {
      type: 'comment_reply',
      post_id: postId,
      comment_id: commentId,
    });
    await stampPushSent([recipientId]);
  } catch (err) {
    console.error('[Firebase] notifyCommentReply error:', err);
  }
}

/**
 * Send push notification for a new DM.
 *
 * For E2EE conversations the notification body is ALWAYS generic —
 * the server doesn't have plaintext, and even if it did, leaking it
 * in a push payload would defeat the point of E2EE. The data payload
 * carries the conversation id + message id so the client can fetch
 * + decrypt + (in v2) update the notification preview locally via a
 * Notification Service Extension.
 */
export async function notifyNewDM(
  recipientId: string,
  senderName: string,
  messageBody: string | null,
  conversationId: string,
  groupName?: string | null,
  options?: { isE2ee?: boolean; messageId?: string },
): Promise<void> {
  try {
    // Check if recipient has messages notifications enabled
    const enabled = await isNotificationEnabled(recipientId, 'messages');
    if (!enabled) return;

    const recipients = await getTokensByUser([recipientId]);
    if (recipients.length === 0 || recipients[0].tokens.length === 0) return;

    let body: string;
    if (options?.isE2ee) {
      // E2EE: never reveal anything about the content. Just the fact
      // a message arrived. In v2 the client-side NSE can optionally
      // fetch + decrypt to show a preview locally.
      body = groupName ? 'New message' : 'Sent you a message';
    } else if (messageBody) {
      body = messageBody.length > 100
        ? messageBody.substring(0, 100) + '…'
        : messageBody;
    } else {
      body = 'Sent you a photo';
    }

    // For groups, show "{group name}" as title and prefix the body with
    // the sender so recipients know who spoke. For 1:1s, the sender's
    // own display name is the title (unchanged behavior).
    const title = groupName ? groupName : senderName;
    const displayBody = groupName ? `${senderName}: ${body}` : body;

    const data: Record<string, string> = {
      type: 'dm',
      conversation_id: conversationId,
    };
    if (options?.messageId) data.message_id = options.messageId;
    if (options?.isE2ee) data.is_e2ee = 'true';

    // Per-recipient badge: includes this new message in the
    // recipient's unread DM count (the message row was inserted
    // before this notify call, so the count is accurate).
    //
    // DMs deliberately bypass filterByPushThrottle — a friend
    // texting should buzz every time. We DO stamp push_sent_at
    // after, though, so a non-DM event arriving during an active
    // DM thread gets throttled (the user doesn't need a "new post"
    // buzz layered on top of conversation buzzes).
    await sendPushWithBadge(recipients, title, displayBody, data);
    await stampPushSent([recipientId]);
  } catch (err) {
    console.error('[Firebase] notifyNewDM error:', err);
  }
}
