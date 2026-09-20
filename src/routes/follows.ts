import { Router } from 'express';
import { query } from '../db/pool';

import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, isMutualFollow, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { createConnection, pushConnection } from '../lib/connections';
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

    const result = await createConnection(req.user!.userId, { userId: user_id });
    await pushConnection(result);
    res.status(result.isNew ? 201 : 200).json({ follow: result.follow, is_mutual: result.isMutual });
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
