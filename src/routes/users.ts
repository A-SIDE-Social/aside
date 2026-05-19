import { Router } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { query, getClient } from '../db/pool';
import { asyncHandler, isMutualFollow, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { keyBundleLimit, usernameLookupLimit } from '../middleware/rateLimit';
import { getPlanLimits, LIMITS, SYSTEM_USER_EMAIL } from '../constants';
import { config } from '../config';
import { getPresignedUploadUrl } from '../storage';
import { SLUG_REGEX } from '../lib/slugs';

const router = Router();

async function canFetchKeyBundle(requesterId: string, targetId: string): Promise<boolean> {
  if (requesterId === targetId) return false;
  if (await isMutualFollow(requesterId, targetId)) return true;

  const { rows } = await query(
    `SELECT 1
     FROM conversation_members requester
     JOIN conversation_members target
       ON target.conversation_id = requester.conversation_id
     WHERE requester.user_id = $1
       AND target.user_id = $2
     LIMIT 1`,
    [requesterId, targetId],
  );
  return rows.length > 0;
}

// GET /me
router.get(
  '/me',
  asyncHandler(async (req: any, res: any) => {
    const { rows } = await query(
      'SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL',
      [req.user!.userId],
    );
    if (rows.length === 0) throw new AppError(404, 'User not found');

    const user = rows[0];
    if (user.avatar_url) user.avatar_url = resolveMediaUrl(user.avatar_url, req);
    const plan = getPlanLimits(user.subscription_status);
    res.json({
      user,
      plan_limits: {
        feed_history_days: plan.feedHistoryDays,
        max_photos_per_post: LIMITS.maxPhotosPerPost,
        max_groups: LIMITS.maxGroups,
        max_video_story_seconds: LIMITS.maxVideoStorySeconds,
        max_invites: LIMITS.maxInvites,
        max_bio_length: LIMITS.maxBioLength,
        max_caption_length: LIMITS.maxCaptionLength,
        max_comment_length: LIMITS.maxCommentLength,
        max_group_name_length: LIMITS.maxGroupNameLength,
        story_expiration_hours: LIMITS.storyExpirationHours,
      },
    });
  }),
);

// POST /me/upload-url - Get presigned upload URL for avatar media.
// Dedicated endpoint (previously cross-wired to /stories/upload-url). Key
// prefix is `avatars/` so bucket lifecycle rules can target avatars separately.
router.post(
  '/me/upload-url',
  asyncHandler(async (req: any, res: any) => {
    const { content_type } = req.body;
    if (!content_type) throw new AppError(400, 'content_type is required');

    // Flat key (no slash) to stay compatible with the dev upload handler,
    // which resolves a single `:filename` segment. `avatar-` prefix keeps
    // objects identifiable in storage logs / S3 listings.
    const key = `avatar-${uuidv4()}`;
    const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';

    let upload_url: string;
    if (isDev) {
      const host = req.get('x-forwarded-host') || req.get('host');
      const proto = req.get('x-forwarded-proto') || req.protocol;
      const baseUrl = `${proto}://${host}`;
      upload_url = `${baseUrl}/v1/posts/upload/${key}`;
    } else {
      upload_url = await getPresignedUploadUrl(key, content_type);
    }

    res.json({ upload_url, key });
  }),
);

// PATCH /me
router.patch(
  '/me',
  asyncHandler(async (req: any, res: any) => {
    const { display_name, bio, avatar_url } = req.body;
    const fields: string[] = [];
    const values: any[] = [];
    let idx = 1;

    if (display_name !== undefined) {
      fields.push(`display_name = $${idx++}`);
      values.push(display_name);
    }
    if (bio !== undefined) {
      fields.push(`bio = $${idx++}`);
      values.push(bio);
    }
    if (avatar_url !== undefined) {
      fields.push(`avatar_url = $${idx++}`);
      values.push(avatar_url || null);
    }

    if (fields.length === 0) throw new AppError(400, 'No fields to update');

    fields.push(`updated_at = NOW()`);
    values.push(req.user!.userId);

    const { rows } = await query(
      `UPDATE users SET ${fields.join(', ')} WHERE id = $${idx} AND deleted_at IS NULL RETURNING *`,
      values,
    );
    if (rows.length === 0) throw new AppError(404, 'User not found');

    const user = rows[0];
    if (user.avatar_url) user.avatar_url = resolveMediaUrl(user.avatar_url, req);
    res.json({ user });
  }),
);

// GET /search?q=... — still active for family management.
//
// The personal-invite-link plan called for locking this down (the
// "no public search" promise). BUT existing shipped app builds use
// this endpoint to find users to add to a family subscription —
// see `family_management_screen.dart`. Returning 410 would break
// that flow for everyone on a build that hasn't yet been replaced.
//
// Proper fix is a follow-up: either (a) migrate family management
// to a slug-based add flow, or (b) constrain this endpoint to
// search only over mutual follows (preserving the no-stranger-
// discovery property while still serving the family use case).
// Until then, leave the endpoint working as-is.
router.get(
  '/search',
  asyncHandler(async (req: any, res: any) => {
    const q = (req.query.q as string || '').trim();
    if (!q || q.length < 1) throw new AppError(400, 'Search query is required');

    const { rows } = await query(
      `SELECT id, display_name, avatar_url
       FROM users
       WHERE deleted_at IS NULL
         AND id != $1
         AND display_name ILIKE $2
       ORDER BY display_name ASC
       LIMIT 20`,
      [req.user!.userId, `%${q}%`],
    );

    for (const row of rows) {
      if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
    }
    res.json({ users: rows });
  }),
);

// GET /by-slug/:slug — exact-match lookup of a user by their personal
// invite slug. Used by the in-app "Send request to [Name]?" confirmation
// screen after a Universal Link / App Link opens the app from a tap on
// `<configured-app-url>/<slug>`.
//
// Returns the minimal payload needed to render that screen: id,
// display_name, avatar_url. NO bio, NO posts, NO follow-status,
// NO mutual-count — the goal is identity confirmation, not profile
// discovery.
//
// Hard rate-limited via usernameLookupLimit (20/min per authenticated
// user) so that even a compromised credential can't be used to walk
// the slug space.
router.get(
  '/by-slug/:slug',
  usernameLookupLimit,
  asyncHandler(async (req: any, res: any) => {
    const slug = (req.params.slug || '').toString().toLowerCase();
    if (!SLUG_REGEX.test(slug)) throw new AppError(400, 'Invalid slug format');

    // Mirror the rejection list from POST /invite-link/request — deleted
    // users and the system account are not addressable here either.
    const { rows } = await query(
      `SELECT id, display_name, avatar_url
       FROM users
       WHERE LOWER(invite_slug) = $1
         AND deleted_at IS NULL
         AND email != $2`,
      [slug, SYSTEM_USER_EMAIL],
    );
    if (rows.length === 0) throw new AppError(404, 'Invite link not found');

    const user = rows[0];
    if (user.avatar_url) user.avatar_url = resolveMediaUrl(user.avatar_url, req);
    res.json({ user });
  }),
);

// GET /:id - Get user profile by ID
router.get(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const { rows } = await query(
      'SELECT id, display_name, avatar_url, bio FROM users WHERE id = $1 AND deleted_at IS NULL',
      [req.params.id],
    );
    if (rows.length === 0) throw new AppError(404, 'User not found');

    const targetUser = rows[0];
    const mutual = await isMutualFollow(req.user!.userId, targetUser.id);

    const profile: any = {
      id: targetUser.id,
      display_name: targetUser.display_name,
      avatar_url: targetUser.avatar_url ? resolveMediaUrl(targetUser.avatar_url, req) : null,
    };

    if (mutual) {
      profile.bio = targetUser.bio;
      profile.is_mutual_follow = true;
    }

    // Check if current user follows this user
    const { rows: followCheck } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [req.user!.userId, targetUser.id],
    );
    profile.is_following = followCheck.length > 0;

    // Check if this user follows the current user
    const { rows: reverseCheck } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [targetUser.id, req.user!.userId],
    );
    profile.is_followed_by = reverseCheck.length > 0;

    // Count the target user's mutual follows. Mirrors the list query in
    // GET /follows/mutual/:userId so the displayed list and the count
    // never disagree (e.g. viewing a friend whose only mutual is you —
    // the list shows you, the count must say 1).
    const { rows: mutualCount } = await query(
      `SELECT COUNT(*) AS count
       FROM follows f1
       JOIN follows f2
         ON f2.follower_id = f1.followee_id
         AND f2.followee_id = f1.follower_id
       JOIN users u ON u.id = f1.followee_id
       WHERE f1.follower_id = $1
         AND u.deleted_at IS NULL
         AND u.email != $2`,
      [targetUser.id, SYSTEM_USER_EMAIL],
    );
    profile.mutual_follow_count = Number(mutualCount[0]?.count || 0);

    res.json({ user: profile });
  }),
);

// GET /me/notification-preferences
router.get(
  '/me/notification-preferences',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { rows } = await query(
      'SELECT connections, posts, comments, messages FROM notification_preferences WHERE user_id = $1',
      [userId],
    );

    const prefs = rows.length > 0
      ? rows[0]
      : { connections: true, posts: true, comments: true, messages: true };

    res.json({ notification_preferences: prefs });
  }),
);

// PATCH /me/notification-preferences
router.patch(
  '/me/notification-preferences',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { connections, posts, comments, messages } = req.body;

    // Validate at least one field
    if (connections === undefined && posts === undefined && comments === undefined && messages === undefined) {
      throw new AppError(400, 'At least one preference field is required');
    }

    const { rows } = await query(
      `INSERT INTO notification_preferences (user_id, connections, posts, comments, messages, updated_at)
       VALUES ($1,
         COALESCE($2, true), COALESCE($3, true), COALESCE($4, true), COALESCE($5, true),
         NOW()
       )
       ON CONFLICT (user_id) DO UPDATE SET
         connections = COALESCE($2, notification_preferences.connections),
         posts = COALESCE($3, notification_preferences.posts),
         comments = COALESCE($4, notification_preferences.comments),
         messages = COALESCE($5, notification_preferences.messages),
         updated_at = NOW()
       RETURNING connections, posts, comments, messages`,
      [userId, connections ?? null, posts ?? null, comments ?? null, messages ?? null],
    );

    res.json({ notification_preferences: rows[0] });
  }),
);

// POST /me/feed-seen — mark Home as just-viewed.
//
// Bumps `users.last_feed_seen_at` to now. The unread-posts half of
// the app-icon badge count (see `getUserBadgeCount` in firebase.ts)
// counts posts created after this timestamp, so calling this clears
// the post side of the badge until the next post arrives.
//
// Mobile calls this on:
//   - FeedScreen mount (cold start when Home is the initial route)
//   - Bottom-nav Home tab tap (re-entering Home from another tab)
//
// Idempotent / cheap — single UPDATE, no return shape beyond 200.
router.post(
  '/me/feed-seen',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    await query(
      'UPDATE users SET last_feed_seen_at = NOW() WHERE id = $1',
      [userId],
    );
    res.json({ ok: true });
  }),
);

// DELETE /me
router.delete(
  '/me',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    // Before soft-deleting, hand off admin on any group conversations
    // this user created. Otherwise those groups would be headless (the
    // normal leave path requires explicit transfer, but account deletion
    // is a forced exit). Promote the oldest-joined remaining member.
    //
    // This runs outside a transaction for simplicity — each UPDATE is
    // independent, and if the soft-delete fails below we still end up
    // with a well-formed admin chain on every group.
    const { rows: creatorships } = await query(
      `SELECT c.id
       FROM conversations c
       WHERE c.conversation_type = 'group'
         AND c.created_by = $1`,
      [userId],
    );

    for (const { id: convId } of creatorships) {
      const { rows: nextAdmin } = await query(
        `SELECT user_id FROM conversation_members
         WHERE conversation_id = $1 AND user_id != $2
         ORDER BY joined_at ASC
         LIMIT 1`,
        [convId, userId],
      );
      if (nextAdmin.length > 0) {
        await query(
          'UPDATE conversations SET created_by = $1 WHERE id = $2',
          [nextAdmin[0].user_id, convId],
        );
      } else {
        // Sole-creator-sole-member: dissolve the group. Nobody's here
        // to inherit it, so leaving the row would orphan it (0 members,
        // stale created_by referencing a soft-deleted user). Dissolve
        // cleans messages first (no ON DELETE CASCADE on messages).
        await query('DELETE FROM messages WHERE conversation_id = $1', [convId]);
        await query('DELETE FROM conversations WHERE id = $1', [convId]);
      }
    }

    // Remove the leaving user from any group memberships so they stop
    // receiving fanout. (Direct conversations are left alone — their
    // counterpart still sees the history.)
    await query(
      `DELETE FROM conversation_members
       WHERE user_id = $1
         AND conversation_id IN (
           SELECT id FROM conversations WHERE conversation_type = 'group'
         )`,
      [userId],
    );

    const { rows } = await query(
      'UPDATE users SET deleted_at = NOW() WHERE id = $1 AND deleted_at IS NULL RETURNING id',
      [userId],
    );
    if (rows.length === 0) throw new AppError(404, 'User not found');

    res.json({ message: 'Account deleted' });
  }),
);

// GET /:id/keybundle — E2EE key bundle for a peer (Phase 1c).
//
// Returns the target user's identity public key, current signed
// prekey, ONE unconsumed one-time prekey, and ONE unconsumed Kyber
// prekey. Both prekeys are atomically marked consumed. If the user
// has no active keys, 404. If either prekey pool is empty, the
// response is 503 — libsignal's PreKeyBundle requires a Kyber
// prekey, so we can't hand out an incomplete bundle and expect the
// peer to do anything useful with it.
//
// Rate limit: 60/hour per caller (see keyBundleLimit comment).
router.get(
  '/:id/keybundle',
  keyBundleLimit,
  asyncHandler(async (req: any, res: any) => {
    const requesterId = req.user!.userId;
    const targetId = req.params.id;
    if (!targetId) throw new AppError(400, 'user id required');
    if (!(await canFetchKeyBundle(requesterId, targetId))) {
      throw new AppError(
        403,
        'Must be mutual followers or share a conversation to fetch a key bundle',
      );
    }

    const client = await getClient();
    try {
      await client.query('BEGIN');

      const keysResult = await client.query(
        `SELECT identity_key_pub,
                signed_prekey_id, signed_prekey_pub, signed_prekey_sig
         FROM device_keys
         WHERE user_id = $1 AND revoked_at IS NULL`,
        [targetId],
      );
      if (keysResult.rows.length === 0) {
        await client.query('ROLLBACK');
        throw new AppError(404, 'No active key set for this user');
      }
      const dk = keysResult.rows[0];

      // Atomically pick + consume one OTPK. FOR UPDATE SKIP LOCKED
      // means concurrent callers never grab the same row: each gets
      // a different one, or null if the pool is empty.
      const otpkResult = await client.query(
        `WITH picked AS (
           SELECT id
           FROM one_time_prekeys
           WHERE user_id = $1 AND consumed_at IS NULL
           ORDER BY key_id ASC
           LIMIT 1
           FOR UPDATE SKIP LOCKED
         )
         UPDATE one_time_prekeys
         SET consumed_at = now()
         FROM picked
         WHERE one_time_prekeys.id = picked.id
         RETURNING one_time_prekeys.key_id, one_time_prekeys.key_pub`,
        [targetId],
      );

      // Same atomic pick pattern for Kyber. PQC-hybrid X3DH requires
      // it, so a null result means we can't hand out a usable bundle.
      const kpkResult = await client.query(
        `WITH picked AS (
           SELECT id
           FROM kyber_prekeys
           WHERE user_id = $1 AND consumed_at IS NULL
           ORDER BY key_id ASC
           LIMIT 1
           FOR UPDATE SKIP LOCKED
         )
         UPDATE kyber_prekeys
         SET consumed_at = now()
         FROM picked
         WHERE kyber_prekeys.id = picked.id
         RETURNING kyber_prekeys.key_id, kyber_prekeys.key_pub, kyber_prekeys.signature`,
        [targetId],
      );

      if (kpkResult.rows.length === 0) {
        // Rolls back the OTPK consumption — fair to the target user
        // to not burn their OTPK when we can't complete the bundle.
        await client.query('ROLLBACK');
        throw new AppError(
          503,
          'Target user has no Kyber prekeys available; ask them to open the app to replenish',
        );
      }

      await client.query('COMMIT');

      const oneTimePreKey =
        otpkResult.rows.length > 0
          ? {
              id: otpkResult.rows[0].key_id,
              public: Buffer.from(otpkResult.rows[0].key_pub).toString(
                'base64',
              ),
            }
          : null;

      const kyberPreKey = {
        id: kpkResult.rows[0].key_id,
        public: Buffer.from(kpkResult.rows[0].key_pub).toString('base64'),
        signature: Buffer.from(kpkResult.rows[0].signature).toString(
          'base64',
        ),
      };

      res.json({
        identity_key_pub: Buffer.from(dk.identity_key_pub).toString('base64'),
        signed_prekey: {
          id: dk.signed_prekey_id,
          public: Buffer.from(dk.signed_prekey_pub).toString('base64'),
          signature: Buffer.from(dk.signed_prekey_sig).toString('base64'),
        },
        one_time_prekey: oneTimePreKey,
        kyber_prekey: kyberPreKey,
      });
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }),
);

export default router;
