import { Router } from 'express';
import { query } from '../db/pool';

import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, isMutualFollow, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import {
  sendPush,
  getTokensForUsers,
  filterByPushThrottle,
  stampPushSent,
} from '../firebase';
import { SYSTEM_USER_EMAIL } from '../constants';

const router = Router();

// POST / - Follow a user
router.post(
  '/',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const { user_id } = req.body;
    if (!user_id) throw new AppError(400, 'user_id is required');
    if (user_id === req.user!.userId) throw new AppError(400, 'Cannot follow yourself');

    // Verify target user exists
    const { rows: targetUsers } = await query(
      'SELECT id FROM users WHERE id = $1 AND deleted_at IS NULL',
      [user_id],
    );
    if (targetUsers.length === 0) throw new AppError(404, 'User not found');

    // Idempotent create: ON CONFLICT DO NOTHING + fallback SELECT means a
    // duplicate accept (e.g. double-tap, retry after a flaky network) is a
    // no-op success instead of a 409. The client doesn't care whether the
    // row was newly created or already existed — only the end state matters.
    const { rows: inserted } = await query(
      `INSERT INTO follows (follower_id, followee_id)
       VALUES ($1, $2)
       ON CONFLICT (follower_id, followee_id) DO NOTHING
       RETURNING *`,
      [req.user!.userId, user_id],
    );
    const isNew = inserted.length > 0;
    let follows = inserted;
    if (!isNew) {
      const { rows: existing } = await query(
        'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
        [req.user!.userId, user_id],
      );
      follows = existing;
    }

    // Check if mutual (reverse follow exists)
    const { rows: reverseFollow } = await query(
      'SELECT id FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [user_id, req.user!.userId],
    );
    const is_mutual = reverseFollow.length > 0;

    // Only emit notifications / pushes on a *new* follow. A duplicate accept
    // from a retry/double-tap must not re-notify the other side.
    if (!isNew) {
      res.status(200).json({ follow: follows[0], is_mutual });
      return;
    }

    // Get follower's display name for notifications
    const { rows: followerInfo } = await query(
      'SELECT display_name FROM users WHERE id = $1',
      [req.user!.userId],
    );
    const followerName = followerInfo[0]?.display_name || 'Someone';

    if (is_mutual) {
      // Mutual was just established — notify both users
      await query(
        `INSERT INTO notifications (user_id, type, actor_id, reference_type)
         VALUES ($1, 'new_mutual', $2, 'follow'), ($2, 'new_mutual', $1, 'follow')`,
        [req.user!.userId, user_id],
      );

      // Push to the other user (check connections preference + throttle)
      const { rows: prefRows } = await query(
        'SELECT COALESCE((SELECT connections FROM notification_preferences WHERE user_id = $1), true) AS enabled',
        [user_id],
      );
      if (prefRows[0].enabled) {
        const allowed = await filterByPushThrottle([user_id]);
        if (allowed.length > 0) {
          const tokens = await getTokensForUsers([user_id]);
          if (tokens.length > 0) {
            await sendPush(tokens, 'New Connection', `You and ${followerName} are now connected`, {
              type: 'new_mutual',
              user_id: req.user!.userId,
            });
            await stampPushSent([user_id]);
          }
        }
      }
    } else {
      // One-way follow — send inbound_follow notification to the followee
      await query(
        `INSERT INTO notifications (user_id, type, actor_id, reference_type)
         VALUES ($1, 'inbound_follow', $2, 'follow')`,
        [user_id, req.user!.userId],
      );

      // Push notification for the connection request (check connections preference + throttle)
      const { rows: prefRows } = await query(
        'SELECT COALESCE((SELECT connections FROM notification_preferences WHERE user_id = $1), true) AS enabled',
        [user_id],
      );
      if (prefRows[0].enabled) {
        const allowed = await filterByPushThrottle([user_id]);
        if (allowed.length > 0) {
          const tokens = await getTokensForUsers([user_id]);
          if (tokens.length > 0) {
            await sendPush(tokens, 'Connection Request', `${followerName} wants to connect with you`, {
              type: 'inbound_follow',
              user_id: req.user!.userId,
            });
            await stampPushSent([user_id]);
          }
        }
      }
    }

    res.status(201).json({ follow: follows[0], is_mutual });
  }),
);

// DELETE /:user_id - Unfollow
router.delete(
  '/:user_id',
  asyncHandler(async (req: any, res: any) => {
    const { user_id } = req.params;

    const { rowCount } = await query(
      'DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [req.user!.userId, user_id],
    );
    if (rowCount === 0) throw new AppError(404, 'Follow not found');

    res.json({ message: 'Unfollowed' });
  }),
);

// DELETE /inbound/:user_id - Decline / remove an inbound follow request.
//
// Distinct from the unfollow endpoint above: that one deletes a row
// where the caller is the FOLLOWER. This one deletes a row where the
// caller is the FOLLOWEE (someone else followed the caller, and the
// caller wants to remove the request without reciprocating).
//
// Idempotent: returns 204 whether the row existed or not, so the
// mobile decline button doesn't surface a confusing error if the
// user has already dismissed via another device.
//
// Also clears the corresponding `inbound_follow` notification so the
// recipient's notification feed doesn't keep showing a request they
// just declined.
router.delete(
  '/inbound/:user_id',
  asyncHandler(async (req: any, res: any) => {
    const { user_id } = req.params;
    const callerId = req.user!.userId;

    await query(
      'DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [user_id, callerId],
    );
    await query(
      `DELETE FROM notifications
       WHERE user_id = $1 AND actor_id = $2 AND type = 'inbound_follow'`,
      [callerId, user_id],
    );

    res.status(204).end();
  }),
);

// GET /mutual - List mutual follows
router.get(
  '/mutual',
  asyncHandler(async (req: any, res: any) => {
    const { rows } = await query(
      `SELECT u.id, u.username, u.display_name, u.avatar_url
       FROM follows f1
       JOIN follows f2
         ON f2.follower_id = f1.followee_id
         AND f2.followee_id = f1.follower_id
       JOIN users u ON u.id = f1.followee_id
       WHERE f1.follower_id = $1
         AND u.deleted_at IS NULL
         AND u.email != $2`,
      [req.user!.userId, SYSTEM_USER_EMAIL],
    );

    for (const row of rows) {
      if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
    }
    res.json({ users: rows });
  }),
);

// GET /mutual/:userId - View another user's connections (with your relationship to each)
router.get(
  '/mutual/:userId',
  asyncHandler(async (req: any, res: any) => {
    const currentUserId = req.user!.userId;
    const targetUserId = req.params.userId;

    // Allow viewing own connections (same as GET /mutual but with relationship annotations)
    if (targetUserId !== currentUserId) {
      const mutual = await isMutualFollow(currentUserId, targetUserId);
      if (!mutual) throw new AppError(403, 'Must be connected to view connections');
    }

    const { rows } = await query(
      `SELECT u.id, u.username, u.display_name, u.avatar_url,
         EXISTS(SELECT 1 FROM follows WHERE follower_id = $2 AND followee_id = u.id) AS i_follow_them,
         EXISTS(SELECT 1 FROM follows WHERE follower_id = u.id AND followee_id = $2) AS they_follow_me
       FROM follows f1
       JOIN follows f2
         ON f2.follower_id = f1.followee_id
         AND f2.followee_id = f1.follower_id
       JOIN users u ON u.id = f1.followee_id
       WHERE f1.follower_id = $1
         AND u.deleted_at IS NULL
         AND u.email != $3
       ORDER BY u.display_name ASC`,
      [targetUserId, currentUserId, SYSTEM_USER_EMAIL],
    );

    for (const row of rows) {
      if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
      row.is_mutual = row.i_follow_them && row.they_follow_me;
    }
    res.json({ users: rows });
  }),
);

// GET /inbound - Users who follow you but you don't follow back
router.get(
  '/inbound',
  asyncHandler(async (req: any, res: any) => {
    const { rows } = await query(
      `SELECT u.id, u.username, u.display_name, u.avatar_url
       FROM follows f
       JOIN users u ON u.id = f.follower_id
       WHERE f.followee_id = $1
         AND u.deleted_at IS NULL
         AND NOT EXISTS (
           SELECT 1 FROM follows f2
           WHERE f2.follower_id = $1
             AND f2.followee_id = f.follower_id
         )`,
      [req.user!.userId],
    );

    for (const row of rows) {
      if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
    }
    res.json({ users: rows });
  }),
);

// GET /outbound - Users you follow who don't follow back
router.get(
  '/outbound',
  asyncHandler(async (req: any, res: any) => {
    const { rows } = await query(
      `SELECT u.id, u.username, u.display_name, u.avatar_url
       FROM follows f
       JOIN users u ON u.id = f.followee_id
       WHERE f.follower_id = $1
         AND u.deleted_at IS NULL
         AND NOT EXISTS (
           SELECT 1 FROM follows f2
           WHERE f2.follower_id = f.followee_id
             AND f2.followee_id = $1
         )`,
      [req.user!.userId],
    );

    for (const row of rows) {
      if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
    }
    res.json({ users: rows });
  }),
);

export default router;
