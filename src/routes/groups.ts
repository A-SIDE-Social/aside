import { Router } from 'express';
import { query } from '../db/pool';
import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, isMutualFollow, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { LIMITS } from '../constants';

const router = Router();

// GET / - List current user's groups
router.get(
  '/',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const { rows } = await query(
      `SELECT * FROM groups WHERE user_id = $1
       ORDER BY position ASC NULLS LAST, created_at ASC`,
      [userId],
    );

    res.json({ groups: rows });
  }),
);

// POST / - Create a group
router.post(
  '/',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { name, color, position } = req.body;

    if (!name) throw new AppError(400, 'name is required');
    if (name.length > LIMITS.maxGroupNameLength) {
      throw new AppError(400, `name must be ${LIMITS.maxGroupNameLength} characters or fewer`);
    }

    // Check group count limit
    const { rows: countRows } = await query(
      'SELECT COUNT(*)::int AS count FROM groups WHERE user_id = $1',
      [userId],
    );
    if (countRows[0].count >= LIMITS.maxGroups) {
      throw new AppError(400, `Maximum ${LIMITS.maxGroups} groups allowed`);
    }

    // Check uniqueness per user
    const { rows: existing } = await query(
      'SELECT id FROM groups WHERE user_id = $1 AND name = $2',
      [userId, name],
    );
    if (existing.length > 0) throw new AppError(409, 'A group with this name already exists');

    const { rows: groups } = await query(
      `INSERT INTO groups (user_id, name, color, position)
       VALUES ($1, $2, $3, $4) RETURNING *`,
      [userId, name, color || null, position ?? null],
    );

    res.status(201).json({ group: groups[0] });
  }),
);

// PATCH /:id - Update a group
router.patch(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { name, color, position } = req.body;

    // Verify ownership
    const { rows: existing } = await query(
      'SELECT * FROM groups WHERE id = $1 AND user_id = $2',
      [id, userId],
    );
    if (existing.length === 0) throw new AppError(404, 'Group not found');

    if (name !== undefined && name.length > 30) {
      throw new AppError(400, 'name must be 30 characters or fewer');
    }

    // Check name uniqueness if name is being changed
    if (name !== undefined && name !== existing[0].name) {
      const { rows: dup } = await query(
        'SELECT id FROM groups WHERE user_id = $1 AND name = $2 AND id != $3',
        [userId, name, id],
      );
      if (dup.length > 0) throw new AppError(409, 'A group with this name already exists');
    }

    const { rows: groups } = await query(
      `UPDATE groups
       SET name = COALESCE($3, name),
           color = COALESCE($4, color),
           position = COALESCE($5, position),
           updated_at = NOW()
       WHERE id = $1 AND user_id = $2
       RETURNING *`,
      [id, userId, name ?? null, color ?? null, position ?? null],
    );

    res.json({ group: groups[0] });
  }),
);

// DELETE /:id - Delete a group
router.delete(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    // Verify ownership
    const { rows: existing } = await query(
      'SELECT id FROM groups WHERE id = $1 AND user_id = $2',
      [id, userId],
    );
    if (existing.length === 0) throw new AppError(404, 'Group not found');

    // Remove post_groups references for posts that are ONLY scoped to this group
    // (those posts become visible to all mutuals)
    await query(
      `DELETE FROM post_groups
       WHERE post_id IN (
         SELECT pg.post_id FROM post_groups pg
         WHERE pg.post_id NOT IN (
           SELECT pg2.post_id FROM post_groups pg2 WHERE pg2.group_id != $1
         )
       ) AND group_id = $1`,
      [id],
    );

    // Delete remaining post_groups references for this group
    await query('DELETE FROM post_groups WHERE group_id = $1', [id]);

    // Delete the group (cascades to group_members)
    await query('DELETE FROM groups WHERE id = $1', [id]);

    res.json({ message: 'Group deleted' });
  }),
);

// GET /:id/members - List members of a group
router.get(
  '/:id/members',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    // Verify ownership
    const { rows: existing } = await query(
      'SELECT id FROM groups WHERE id = $1 AND user_id = $2',
      [id, userId],
    );
    if (existing.length === 0) throw new AppError(404, 'Group not found');

    // List members filtered to active mutual follows
    const { rows } = await query(
      `SELECT u.id, u.username, u.display_name, u.avatar_url
       FROM group_members gm
       JOIN users u ON u.id = gm.member_user_id
       WHERE gm.group_id = $1
         AND u.deleted_at IS NULL
         AND EXISTS (
           SELECT 1 FROM follows f1
           JOIN follows f2
             ON f2.follower_id = f1.followee_id
             AND f2.followee_id = f1.follower_id
           WHERE f1.follower_id = $2
             AND f1.followee_id = gm.member_user_id
         )`,
      [id, userId],
    );

    for (const row of rows) {
      if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
    }
    res.json({ members: rows });
  }),
);

// PUT /:id/members - Replace full member list
router.put(
  '/:id/members',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { user_ids } = req.body;

    if (!Array.isArray(user_ids)) throw new AppError(400, 'user_ids must be an array');

    // Verify ownership
    const { rows: existing } = await query(
      'SELECT id FROM groups WHERE id = $1 AND user_id = $2',
      [id, userId],
    );
    if (existing.length === 0) throw new AppError(404, 'Group not found');

    // Verify all user_ids are mutual follows
    for (const uid of user_ids) {
      const mutual = await isMutualFollow(userId, uid);
      if (!mutual) throw new AppError(400, `User ${uid} is not a mutual follow`);
    }

    // Delete existing members
    await query('DELETE FROM group_members WHERE group_id = $1', [id]);

    // Insert new members
    if (user_ids.length > 0) {
      const values = user_ids.map((_: string, i: number) => `($1, $${i + 2})`).join(', ');
      await query(
        `INSERT INTO group_members (group_id, member_user_id) VALUES ${values}`,
        [id, ...user_ids],
      );
    }

    res.json({ message: 'Members updated' });
  }),
);

export default router;
