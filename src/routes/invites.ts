import { Router } from 'express';
import crypto from 'crypto';
import { query } from '../db/pool';
import { authenticate } from '../middleware/auth';
import { writeLimit, inviteValidateLimit } from '../middleware/rateLimit';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { LIMITS } from '../constants';

function generateInviteCode(): string {
  return crypto.randomUUID().replace(/-/g, '').slice(0, 12);
}

const router = Router();

// GET / - List current user's invites
router.get(
  '/',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const { rows } = await query(
      `SELECT * FROM invites WHERE created_by_user_id = $1 ORDER BY created_at DESC`,
      [userId],
    );

    res.json({ invites: rows });
  }),
);

// POST / - Generate a new invite
router.post(
  '/',
  authenticate,
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    // Check invite limit
    const { rows: countRows } = await query(
      `SELECT COUNT(*) AS count FROM invites
       WHERE created_by_user_id = $1 AND status IN ('pending', 'sent', 'used')`,
      [userId],
    );
    if (parseInt(countRows[0].count, 10) >= LIMITS.maxInvites) {
      throw new AppError(400, `Maximum of ${LIMITS.maxInvites} pending or used invites allowed`);
    }

    const code = generateInviteCode();

    // Set expires_at to 30 days from now
    const { rows: invites } = await query(
      `INSERT INTO invites (created_by_user_id, code, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '30 days') RETURNING *`,
      [userId, code],
    );

    res.status(201).json({ invite: invites[0] });
  }),
);

// PATCH /:id - Update invite status (user can only set 'sent')
router.patch(
  '/:id',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { status } = req.body;

    if (status !== 'sent') {
      throw new AppError(400, "Only 'sent' status can be set by the user");
    }

    const { rows } = await query(
      `UPDATE invites SET status = 'sent'
       WHERE id = $1 AND created_by_user_id = $2 AND status = 'pending'
       RETURNING *`,
      [id, userId],
    );
    if (rows.length === 0) throw new AppError(404, 'Pending invite not found');

    res.json({ invite: rows[0] });
  }),
);

// DELETE /:id - Revoke a pending invite
router.delete(
  '/:id',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    // Verify ownership and redeemable status (pending or sent)
    const { rows: existing } = await query(
      `SELECT id FROM invites WHERE id = $1 AND created_by_user_id = $2 AND status IN ('pending', 'sent')`,
      [id, userId],
    );
    if (existing.length === 0) throw new AppError(404, 'Pending invite not found');

    await query(
      `UPDATE invites SET status = 'revoked' WHERE id = $1`,
      [id],
    );

    res.json({ message: 'Invite revoked' });
  }),
);

// POST /redeem - Redeem an invite code (existing user)
router.post(
  '/redeem',
  authenticate,
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const { code } = req.body;
    const userId = req.user!.userId;

    if (!code) throw new AppError(400, 'code is required');

    // Validate the invite code
    const { rows: invites } = await query(
      `SELECT i.id, i.created_by_user_id
       FROM invites i
       WHERE i.code = $1
         AND i.status IN ('pending', 'sent')
         AND i.expires_at > NOW()`,
      [code],
    );
    if (invites.length === 0) throw new AppError(404, 'Invalid or expired invite code');

    const invite = invites[0];

    // Cannot redeem your own invite
    if (invite.created_by_user_id === userId) {
      throw new AppError(400, 'Cannot redeem your own invite');
    }

    const inviterId = invite.created_by_user_id;

    // Check if already connected (mutual follow exists)
    const { rows: existingFollow } = await query(
      `SELECT id FROM follows WHERE follower_id = $1 AND followee_id = $2
       AND EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followee_id = $1)`,
      [userId, inviterId],
    );
    if (existingFollow.length > 0) {
      throw new AppError(409, 'You are already connected with this user');
    }

    // Mark invite as used
    await query(
      `UPDATE invites SET status = 'used', used_by_user_id = $1, used_at = NOW() WHERE id = $2`,
      [userId, invite.id],
    );

    // Create mutual follow (auto-connect)
    await query(
      `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2), ($2, $1)
       ON CONFLICT DO NOTHING`,
      [userId, inviterId],
    );

    // Create new_mutual notifications for both
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'new_mutual', $2, 'follow'), ($2, 'new_mutual', $1, 'follow')`,
      [userId, inviterId],
    );

    res.json({ message: 'Connected successfully', is_mutual: true });
  }),
);

// GET /validate/:code - Check if invite code is valid (no auth required)
router.get(
  '/validate/:code',
  inviteValidateLimit,
  asyncHandler(async (req: any, res: any) => {
    const { code } = req.params;

    const { rows } = await query(
      `SELECT i.id, u.display_name
       FROM invites i
       JOIN users u ON u.id = i.created_by_user_id
       WHERE i.code = $1
         AND i.status IN ('pending', 'sent')
         AND i.expires_at > NOW()`,
      [code],
    );

    if (rows.length === 0) {
      return res.json({ valid: false });
    }

    res.json({
      valid: true,
      inviter: {
        display_name: rows[0].display_name,
      },
    });
  }),
);

export default router;
